//
//  ADBSyncDeviceTests.swift
//  ConduitCoreTests
//
//  The sync client against a real phone, when one is named:
//
//      CONDUIT_PHONE=<adb serial> swift test --filter ADBSyncDeviceTests
//
//  It looks only for the standard folders and never reads out the names of
//  anyone's files. It sends one test file to Download — with a space and an
//  apostrophe in its name — checks it byte for byte both ways and on the
//  phone itself, and deletes it.
//

import CryptoKit
import Foundation
import Testing
@testable import ConduitCore

@Suite("adb file sync on a real phone", .enabled(if: ProcessInfo.processInfo.environment["CONDUIT_PHONE"] != nil))
struct ADBSyncDeviceTests {

    let serial = ProcessInfo.processInfo.environment["CONDUIT_PHONE"] ?? ""
    let root = "/storage/emulated/0"

    @Test("list, send, read back and delete on the phone")
    func roundTrip() throws {
        let features = try ADBSyncConnection.features(serial: serial)
        #expect(features.isSuperset(of: ["ls_v2", "stat_v2"]))

        // An odd size, so the last chunk is a partial one.
        let bytes = Data((0 ..< 300_001).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let name = "conduit test it's \(UUID().uuidString.prefix(8)).bin"
        let path = "\(root)/Download/\(name)"
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-device-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let source = local.appendingPathComponent("source.bin")
        try bytes.write(to: source)

        let adb = try #require(ADB.locate())
        defer { _ = adb.run(["-s", serial, "shell", "rm -f -- \(PhoneShell.quote(path))"]) }

        // v2, many requests on one connection.
        do {
            let connection = try ADBSyncConnection(serial: serial, useV2: true)
            defer { connection.close() }

            #expect(try connection.stat(root)?.kind == .directory)
            let top = Set(try connection.list(root).map(\.name))
            #expect(top.isSuperset(of: ["Download", "DCIM"]))

            var sent: UInt64 = 0
            try connection.push(source, to: path) { sent = $0; return true }
            #expect(sent == UInt64(bytes.count))

            let stat = try #require(try connection.stat(path))
            #expect(stat.kind == .file)
            #expect(stat.size == UInt64(bytes.count))

            let listed = try connection.list("\(root)/Download").first { $0.name == name }
            #expect(listed?.size == UInt64(bytes.count))

            let back = local.appendingPathComponent("back.bin")
            try connection.pull(path, to: back) { _ in true }
            #expect(try Data(contentsOf: back) == bytes)

            #expect(throws: ADBSync.Failure.self) {
                try connection.pull("\(root)/Download/conduit-no-such-file-\(UUID().uuidString)",
                                    to: local.appendingPathComponent("missing")) { _ in true }
            }
        }

        // The phone's own reading of the file agrees.
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let onPhone = adb.run(["-s", serial, "shell", "sha256sum -- \(PhoneShell.quote(path))"])
        #expect(onPhone.stdout.hasPrefix(digest))

        // v1 — the older listing and stat — on a fresh connection.
        do {
            let connection = try ADBSyncConnection(serial: serial, useV2: false)
            defer { connection.close() }
            #expect(try connection.list("\(root)/Download").first { $0.name == name }?.size == UInt64(bytes.count))
            #expect(try connection.stat(path)?.size == UInt64(bytes.count))
        }

        // Deleting through the phone's shell, quoted.
        #expect(adb.run(["-s", serial, "shell", "rm -f -- \(PhoneShell.quote(path))"]).ok)
        let connection = try ADBSyncConnection(serial: serial, useV2: true)
        defer { connection.close() }
        #expect(try connection.stat(path) == nil)
    }
}
