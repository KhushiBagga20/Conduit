//
//  ADBSyncTests.swift
//  ConduitCoreTests
//
//  adb's file sync protocol, byte for byte, against a scripted stand-in for
//  the adb server — so the framing is checked without a phone.
//

import Darwin
import Foundation
import Testing
@testable import ConduitCore

@Suite("adb file sync")
struct ADBSyncTests {

    // MARK: - Encoding and decoding

    @Test("requests are framed the way adb expects")
    func encoding() {
        #expect(ADBSync.hostRequest("host:version") == Data("000chost:version".utf8))
        #expect(ADBSync.message("LIST", Data("/sdcard".utf8)) == Data("LIST".utf8) + Data([7, 0, 0, 0]) + Data("/sdcard".utf8))
        #expect(ADBSync.message("DONE", length: 0x01020304) == Data("DONE".utf8) + Data([4, 3, 2, 1]))
        // st_mode for a regular rw-r--r-- file, in decimal.
        #expect(ADBSync.sendPayload(path: "/sdcard/a b.txt", mode: 0o100644) == Data("/sdcard/a b.txt,33188".utf8))
    }

    @Test("listing and stat records are read field by field")
    func decoding() {
        let v1 = Self.dentV1(id: "DENT", mode: 0o040755, size: 4096, mtime: 1_700_000_000, name: "DCIM")
        let header = ADBSync.dentV1(v1.prefix(ADBSync.dentV1Size))
        #expect(header == ADBSync.DentHeader(id: "DENT", error: 0, mode: 0o040755, size: 4096, mtime: 1_700_000_000, nameLength: 4))

        let big: UInt64 = 5 * 1024 * 1024 * 1024
        let v2 = Self.dentV2(id: "DNT2", error: 0, mode: 0o100644, size: big, mtime: 1_800_000_000, name: "film.mp4")
        let header2 = ADBSync.dentV2(v2.prefix(ADBSync.dentV2Size))
        #expect(header2.size == big)
        #expect(header2.mode == 0o100644)
        #expect(header2.mtime == 1_800_000_000)
        #expect(header2.nameLength == 8)

        #expect(ADBSync.statV1(Data("STAT".utf8) + Data(count: 12)) == nil)
        #expect(ADBSync.Kind(mode: 0o040755) == .directory)
        #expect(ADBSync.Kind(mode: 0o100644) == .file)
        #expect(ADBSync.Kind(mode: 0o120777) == .link)
    }

    @Test("names are single-quoted for the phone's shell")
    func quoting() {
        #expect(PhoneShell.quote("Holiday 2026") == "'Holiday 2026'")
        #expect(PhoneShell.quote("it's") == "'it'\\''s'")
        #expect(PhoneShell.quote("$(rm -rf /)") == "'$(rm -rf /)'")
    }

    // MARK: - A whole session

    @Test("list, pull and push through a pretend adb server")
    func session() throws {
        let photo = Data((0 ..< 150_000).map { UInt8($0 % 251) })   // three chunks
        let upload = Data((0 ..< 70_000).map { UInt8($0 % 13) })
        let received = Received()

        let server = try FakeADBServer { client in
            #expect(try client.readHostRequest() == "host:transport:PHONE1")
            try client.write(Data("OKAY".utf8))
            #expect(try client.readHostRequest() == "sync:")
            try client.write(Data("OKAY".utf8))

            // LIST: two entries and the dot entries, then DONE.
            #expect(try client.readSync() == ("LIST", "/sdcard/DCIM"))
            for (name, mode) in [(".", UInt32(0o040755)), ("..", 0o040755), ("Camera", 0o040755), ("a.jpg", 0o100644)] {
                try client.write(Self.dentV1(id: "DENT", mode: mode, size: name == "a.jpg" ? 150_000 : 4096,
                                             mtime: 1_700_000_000, name: name))
            }
            try client.write(Self.dentV1(id: "DONE", mode: 0, size: 0, mtime: 0, name: ""))

            // RECV: the photo in 64 KiB chunks.
            #expect(try client.readSync() == ("RECV", "/sdcard/DCIM/a.jpg"))
            var offset = 0
            while offset < photo.count {
                let chunk = photo[offset ..< min(offset + ADBSync.maximumChunk, photo.count)]
                try client.write(ADBSync.message("DATA", Data(chunk)))
                offset += chunk.count
            }
            try client.write(ADBSync.message("DONE", length: 0))

            // SEND: collect the chunks, then say OKAY.
            let send = try client.readSync()
            #expect(send.0 == "SEND")
            received.sendTarget = send.1
            while true {
                let (id, length) = try client.readHeader()
                if id == "DONE" { break }
                #expect(id == "DATA")
                received.bytes += try client.read(Int(length))
            }
            try client.write(ADBSync.message("OKAY", length: 0))

            // RECV of something missing: FAIL with a reason.
            #expect(try client.readSync() == ("RECV", "/sdcard/gone.txt"))
            let reason = Data("No such file or directory".utf8)
            try client.write(ADBSync.message("FAIL", reason))
        }

        let connection = try ADBSyncConnection(serial: "PHONE1", useV2: false, port: server.port)

        let entries = try connection.list("/sdcard/DCIM")
        #expect(entries.map(\.name) == ["Camera", "a.jpg"])
        #expect(entries.map(\.kind) == [.directory, .file])

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let pulled = folder.appendingPathComponent("a.jpg")
        var progress: [UInt64] = []
        try connection.pull("/sdcard/DCIM/a.jpg", to: pulled) { progress.append($0); return true }
        #expect(try Data(contentsOf: pulled) == photo)
        #expect(progress.last == 150_000)
        // No partial file left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.jpg"])

        let local = folder.appendingPathComponent("notes.txt")
        try upload.write(to: local)
        try connection.push(local, to: "/sdcard/Download/notes.txt") { _ in true }
        #expect(received.sendTarget == "/sdcard/Download/notes.txt,33188")
        #expect(received.bytes == upload)

        #expect(throws: ADBSync.Failure.device("No such file or directory")) {
            try connection.pull("/sdcard/gone.txt", to: folder.appendingPathComponent("gone.txt")) { _ in true }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".gone.txt.conduit-part").path))
        server.wait()
    }

    @Test("v2 listings carry 64-bit sizes and skip entries the phone could not read")
    func listingV2() throws {
        let big: UInt64 = 5 * 1024 * 1024 * 1024
        let server = try FakeADBServer { client in
            _ = try client.readHostRequest(); try client.write(Data("OKAY".utf8))
            _ = try client.readHostRequest(); try client.write(Data("OKAY".utf8))
            #expect(try client.readSync() == ("LIS2", "/sdcard/Movies"))
            try client.write(Self.dentV2(id: "DNT2", error: 0, mode: 0o100644, size: big, mtime: 1_800_000_000, name: "film.mp4"))
            try client.write(Self.dentV2(id: "DNT2", error: 13, mode: 0, size: 0, mtime: 0, name: "secret"))
            try client.write(Self.dentV2(id: "DONE", error: 0, mode: 0, size: 0, mtime: 0, name: ""))
        }
        let connection = try ADBSyncConnection(serial: "PHONE1", useV2: true, port: server.port)
        let entries = try connection.list("/sdcard/Movies")
        #expect(entries == [ADBSync.Entry(name: "film.mp4", mode: 0o100644, size: big, modified: 1_800_000_000)])
        server.wait()
    }

    // MARK: - Records

    static func dentV1(id: String, mode: UInt32, size: UInt32, mtime: UInt32, name: String) -> Data {
        var data = Data(id.utf8)
        for value in [mode, size, mtime, UInt32(name.utf8.count)] { data.append(littleEndian: value) }
        return data + Data(name.utf8)
    }

    static func dentV2(id: String, error: UInt32, mode: UInt32, size: UInt64, mtime: Int64, name: String) -> Data {
        var data = Data(id.utf8)
        data.append(littleEndian: error)
        data.append(u64: 0); data.append(u64: 0)                 // dev, ino
        data.append(littleEndian: mode)
        for _ in 0 ..< 3 { data.append(littleEndian: 0) }        // nlink, uid, gid
        data.append(u64: size)
        data.append(u64: 0)                                      // atime
        data.append(u64: UInt64(bitPattern: mtime))
        data.append(u64: 0)                                      // ctime
        data.append(littleEndian: UInt32(name.utf8.count))
        return data + Data(name.utf8)
    }
}

private final class Received: @unchecked Sendable {
    var sendTarget = ""
    var bytes = Data()
}

private extension Data {
    mutating func append(u64 value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// A stand-in for the adb server: one connection on a random local port,
/// answered by a script.
private final class FakeADBServer: @unchecked Sendable {

    let port: UInt16
    private let listener: Int32
    private let done = DispatchSemaphore(value: 0)

    init(script: @escaping @Sendable (FakeClient) throws -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 1)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: bound.sin_port)

        let done = self.done
        Thread {
            defer { done.signal() }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var limit = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            defer { close(client) }
            do { try script(FakeClient(fd: client)) } catch { Issue.record("fake server: \(error)") }
        }.start()
    }

    deinit { close(listener) }

    func wait() { _ = done.wait(timeout: .now() + 10) }
}

private struct FakeClient {
    let fd: Int32

    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        try data.withUnsafeMutableBytes { raw in
            while got < count {
                let n = Darwin.read(fd, raw.baseAddress! + got, count - got)
                guard n > 0 else { throw ADBSync.Failure.connection("fake server read") }
                got += n
            }
        }
        return data
    }

    func write(_ data: Data) throws {
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) }
    }

    func readHostRequest() throws -> String {
        let length = Int(String(decoding: try read(4), as: UTF8.self), radix: 16) ?? 0
        return String(decoding: try read(length), as: UTF8.self)
    }

    func readHeader() throws -> (String, UInt32) {
        var reader = ADBSync.Reader(try read(8))
        return (reader.id(), reader.u32())
    }

    func readSync() throws -> (String, String) {
        let (id, length) = try readHeader()
        return (id, String(decoding: try read(Int(length)), as: UTF8.self))
    }
}
