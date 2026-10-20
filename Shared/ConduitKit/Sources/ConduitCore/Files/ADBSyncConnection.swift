//
//  ADBSyncConnection.swift
//  ConduitCore
//
//  One sync session with one phone, through the local adb server.
//  Blocking by design — a strict request-and-answer protocol — so every
//  call is made off the main thread. After any thrown error the session
//  may hold unread bytes: close it and open another.
//

import Darwin
import Foundation

nonisolated final class ADBSocket {

    private let fd: Int32
    private var isOpen = true

    init(port: UInt16, timeout: TimeInterval) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ADBSync.Failure.connection("no socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw ADBSync.Failure.connection("the adb server isn't running")
        }
        self.fd = fd
    }

    deinit { close() }

    func close() {
        guard isOpen else { return }
        isOpen = false
        Darwin.close(fd)
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.write(fd, base + sent, raw.count - sent)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ADBSync.Failure.connection(String(cString: strerror(errno))) }
                sent += count
            }
        }
    }

    func read(exactly count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var got = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while got < count {
                let read = Darwin.read(fd, base + got, count - got)
                if read < 0, errno == EINTR { continue }
                if read == 0 { throw ADBSync.Failure.connection("the phone closed the connection") }
                guard read > 0 else { throw ADBSync.Failure.connection(String(cString: strerror(errno))) }
                got += read
            }
        }
        return data
    }

    /// OKAY, or FAIL with the server's reason.
    func readHostStatus() throws {
        let status = String(decoding: try read(exactly: 4), as: UTF8.self)
        switch status {
        case "OKAY": return
        case "FAIL": throw ADBSync.Failure.server(try readHexString())
        default: throw ADBSync.Failure.unexpected("host status \(status)")
        }
    }

    /// Four hex digits of length, then that many bytes of text.
    func readHexString() throws -> String {
        let text = String(decoding: try read(exactly: 4), as: UTF8.self)
        guard let length = Int(text, radix: 16) else { throw ADBSync.Failure.unexpected("length \(text)") }
        return String(decoding: try read(exactly: length), as: UTF8.self)
    }
}

nonisolated final class ADBSyncConnection {

    private let socket: ADBSocket
    private let useV2: Bool

    /// Switch to the phone and enter sync mode. `useV2` when the phone's
    /// adbd advertises `ls_v2` and `stat_v2`: 64-bit sizes and following
    /// links in stat.
    init(serial: String, useV2: Bool, port: UInt16 = ADBSync.serverPort) throws {
        let socket = try ADBSocket(port: port, timeout: 20)
        try socket.write(ADBSync.hostRequest("host:transport:\(serial)"))
        try socket.readHostStatus()
        try socket.write(ADBSync.hostRequest("sync:"))
        try socket.readHostStatus()
        self.socket = socket
        self.useV2 = useV2
    }

    deinit { close() }

    func close() {
        try? socket.write(ADBSync.message("QUIT", length: 0))
        socket.close()
    }

    /// The features a phone's adbd supports, as `adb features` lists them.
    static func features(serial: String, port: UInt16 = ADBSync.serverPort) throws -> Set<String> {
        let socket = try ADBSocket(port: port, timeout: 10)
        defer { socket.close() }
        try socket.write(ADBSync.hostRequest("host-serial:\(serial):features"))
        try socket.readHostStatus()
        return Set(try socket.readHexString().split(separator: ",").map(String.init))
    }

    // MARK: - Listing

    func list(_ path: String) throws -> [ADBSync.Entry] {
        try Self.require(path)
        try socket.write(ADBSync.message(useV2 ? "LIS2" : "LIST", Data(path.utf8)))

        let size = useV2 ? ADBSync.dentV2Size : ADBSync.dentV1Size
        var entries: [ADBSync.Entry] = []
        while true {
            let record = try socket.read(exactly: size)
            let header = useV2 ? ADBSync.dentV2(record) : ADBSync.dentV1(record)
            switch header.id {
            case "DONE":
                return entries
            case "DENT", "DNT2":
                guard header.nameLength <= 4096 else { throw ADBSync.Failure.unexpected("name of \(header.nameLength) bytes") }
                let name = String(decoding: try socket.read(exactly: Int(header.nameLength)), as: UTF8.self)
                // An entry the phone could not stat comes with its errno.
                guard header.error == 0, name != ".", name != ".." else { continue }
                entries.append(ADBSync.Entry(name: name, mode: header.mode, size: header.size, modified: header.mtime))
            case "FAIL":
                throw try failure(in: record)
            default:
                throw ADBSync.Failure.unexpected("listing record \(header.id)")
            }
        }
    }

    /// What is at a path — following links with v2 — or nil if nothing is.
    func stat(_ path: String) throws -> ADBSync.Entry? {
        try Self.require(path)
        if useV2 {
            try socket.write(ADBSync.message("STA2", Data(path.utf8)))
            let record = try socket.read(exactly: ADBSync.statV2Size)
            guard String(decoding: record.prefix(4), as: UTF8.self) == "STA2" else {
                throw try failure(in: record)
            }
            return ADBSync.statV2(record).entry
        }
        try socket.write(ADBSync.message("STAT", Data(path.utf8)))
        let record = try socket.read(exactly: ADBSync.statV1Size)
        guard String(decoding: record.prefix(4), as: UTF8.self) == "STAT" else { throw try failure(in: record) }
        return ADBSync.statV1(record)
    }

    // MARK: - Moving files

    /// Copy a phone file to `destination`, through a hidden partial file
    /// beside it, so a broken transfer never leaves half a file under the
    /// real name. `progress` gets the bytes so far; returning false cancels.
    func pull(_ path: String, to destination: URL, progress: (UInt64) -> Bool) throws {
        try Self.require(path)
        let manager = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).conduit-part")
        guard manager.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial)
        else { throw ADBSync.Failure.connection("couldn't write to \(destination.deletingLastPathComponent().path)") }

        var finished = false
        defer {
            try? handle.close()
            if !finished { try? manager.removeItem(at: partial) }
        }

        try socket.write(ADBSync.message("RECV", Data(path.utf8)))
        var received: UInt64 = 0
        while true {
            var header = ADBSync.Reader(try socket.read(exactly: 8))
            let id = header.id()
            let length = header.u32()
            switch id {
            case "DATA":
                guard length <= UInt32(ADBSync.maximumChunk) else { throw ADBSync.Failure.unexpected("chunk of \(length) bytes") }
                try handle.write(contentsOf: try socket.read(exactly: Int(length)))
                received += UInt64(length)
                guard progress(received) else { throw ADBSync.Failure.cancelled }
            case "DONE":
                try handle.close()
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.moveItem(at: partial, to: destination)
                finished = true
                return
            case "FAIL":
                throw ADBSync.Failure.device(String(decoding: try socket.read(exactly: Int(length)), as: UTF8.self))
            default:
                throw ADBSync.Failure.unexpected("transfer record \(id)")
            }
        }
    }

    /// Copy a Mac file to `path` on the phone. The phone's adbd makes any
    /// missing folders on the way, and removes a partial file if the
    /// transfer breaks.
    func push(_ file: URL, to path: String, mode: UInt32 = 0o100644, progress: (UInt64) -> Bool) throws {
        let payload = ADBSync.sendPayload(path: path, mode: mode)
        guard payload.count <= ADBSync.maximumPath else { throw ADBSync.Failure.unexpected("path too long") }
        try Self.require(path)
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            throw ADBSync.Failure.connection("couldn't read \(file.lastPathComponent)")
        }
        defer { try? handle.close() }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        do {
            try socket.write(ADBSync.message("SEND", payload))
            var sent: UInt64 = 0
            while let chunk = try handle.read(upToCount: ADBSync.maximumChunk), !chunk.isEmpty {
                try socket.write(ADBSync.message("DATA", chunk))
                sent += UInt64(chunk.count)
                guard progress(sent) else { throw ADBSync.Failure.cancelled }
            }
            try socket.write(ADBSync.message("DONE", length: UInt32(clamping: Int(modified.timeIntervalSince1970))))
        } catch ADBSync.Failure.connection(let detail) {
            // The phone may have refused early and closed; its reason is
            // worth more than "broken pipe".
            throw (try? pendingFailure()) ?? ADBSync.Failure.connection(detail)
        }

        var status = ADBSync.Reader(try socket.read(exactly: 8))
        let id = status.id()
        let length = status.u32()
        switch id {
        case "OKAY": return
        case "FAIL": throw ADBSync.Failure.device(String(decoding: try socket.read(exactly: Int(length)), as: UTF8.self))
        default: throw ADBSync.Failure.unexpected("send status \(id)")
        }
    }

    // MARK: - Private

    /// A FAIL record read as though it were a longer one: its first 8 bytes
    /// are the status, the rest the start of the message.
    private func failure(in record: Data) throws -> ADBSync.Failure {
        var reader = ADBSync.Reader(record)
        guard reader.id() == "FAIL" else { return .unexpected("record \(String(decoding: record.prefix(4), as: UTF8.self))") }
        let length = Int(reader.u32())
        var message = Data(record.dropFirst(8).prefix(length))
        if length > message.count { message += try socket.read(exactly: length - message.count) }
        return .device(String(decoding: message, as: UTF8.self))
    }

    private func pendingFailure() throws -> ADBSync.Failure? {
        var header = ADBSync.Reader(try socket.read(exactly: 8))
        guard header.id() == "FAIL" else { return nil }
        return .device(String(decoding: try socket.read(exactly: Int(header.u32())), as: UTF8.self))
    }

    private static func require(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= ADBSync.maximumPath else {
            throw ADBSync.Failure.unexpected("not a phone path")
        }
    }
}

/// Arguments for the phone's own shell, for the few things sync cannot do
/// (making folders, deleting). Every one is single-quoted, so no file name
/// can be read as a command.
nonisolated enum PhoneShell {
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
