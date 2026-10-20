//
//  ADBSyncSpeedTests.swift
//  ConduitCoreTests
//
//  How fast Conduit moves a file, beside adb's own command line, on a real
//  phone. Opt-in, and it cleans up after itself:
//
//      CONDUIT_PHONE=<serial> CONDUIT_SPEED=1 swift test --filter ADBSyncSpeedTests
//

import Foundation
import Testing
@testable import ConduitCore

@Suite("adb file sync speed", .enabled(if: ProcessInfo.processInfo.environment["CONDUIT_SPEED"] != nil))
struct ADBSyncSpeedTests {

    @Test("32 MB each way, beside adb push and pull")
    func speed() throws {
        let serial = try #require(ProcessInfo.processInfo.environment["CONDUIT_PHONE"])
        let adb = try #require(ADB.locate())
        let size = 32 * 1024 * 1024
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.bin")
        // Random, so adb's compression has nothing to gain and the race is fair.
        var random = SystemRandomNumberGenerator()
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for index in words.indices { words[index] = random.next() }
        }
        try bytes.write(to: source)

        let path = "/storage/emulated/0/Download/conduit-speed-\(UUID().uuidString.prefix(8)).bin"
        defer { _ = adb.run(["-s", serial, "shell", "rm -f -- \(PhoneShell.quote(path))"]) }

        func megabytesPerSecond(_ seconds: Double) -> String { String(format: "%.0f MB/s", Double(size) / 1_048_576 / seconds) }
        func time(_ work: () throws -> Void) rethrows -> Double {
            let start = Date()
            try work()
            return Date().timeIntervalSince(start)
        }

        let connection = try ADBSyncConnection(serial: serial, useV2: true)
        defer { connection.close() }
        let ourPush = try time { try connection.push(source, to: path) { _ in true } }
        let ourPull = try time { try connection.pull(path, to: folder.appendingPathComponent("ours.bin")) { _ in true } }
        let theirPush = time { _ = adb.run(["-s", serial, "push", source.path, path], timeout: 120) }
        let theirPull = time { _ = adb.run(["-s", serial, "pull", path, folder.appendingPathComponent("theirs.bin").path], timeout: 120) }

        print("SPEED to phone: Conduit \(megabytesPerSecond(ourPush)), adb \(megabytesPerSecond(theirPush))")
        print("SPEED to Mac:   Conduit \(megabytesPerSecond(ourPull)), adb \(megabytesPerSecond(theirPull))")
        #expect(try Data(contentsOf: folder.appendingPathComponent("ours.bin")).count == size)
    }
}
