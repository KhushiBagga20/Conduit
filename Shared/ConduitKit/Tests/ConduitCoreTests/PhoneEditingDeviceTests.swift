//
//  PhoneEditingDeviceTests.swift
//  ConduitCoreTests
//
//  Editing a phone file in place, against a real phone:
//
//      CONDUIT_PHONE=<adb serial> swift test --filter PhoneEditingDeviceTests
//
//  It works on its own test file in Download and removes it afterwards.
//  Nothing opens on the Mac: the test stands in for the app that would.
//

import ConduitState
import Foundation
import Testing
@testable import ConduitCore

@Suite("Editing a phone file in place", .enabled(if: ProcessInfo.processInfo.environment["CONDUIT_PHONE"] != nil))
@MainActor
struct PhoneEditingDeviceTests {

    let serial = ProcessInfo.processInfo.environment["CONDUIT_PHONE"] ?? ""

    @Test("saves go back to the phone, and a save after the phone's copy changed goes beside it")
    func savesAndConflicts() async throws {
        let adb = try #require(ADB.locate())
        let state = FilesState()
        let files = PhoneFiles(adb: adb, state: state)
        files.openInApp = { _ in }
        files.use(serial: serial)
        try await waitUntil { state.isAvailable && !state.isLoading }

        let name = "conduit-edit-\(UUID().uuidString.prefix(8)).txt"
        let path = "\(FilesState.root)/Download/\(name)"
        let beside = PhoneFiles.besideName(for: path)
        defer {
            _ = adb.run(["-s", serial, "shell", "rm -f -- \(PhoneShell.quote(path)) \(PhoneShell.quote(beside))"])
        }
        try put("first", at: path)

        files.edit(PhoneFile(path: path, name: name, isFolder: false, size: 5, modified: Date()))
        try await waitUntil { state.editing.first?.status == .editing }
        let session = try #require(state.editing.first)
        let copy = try #require(session.workingCopy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "first")

        // Saved on the Mac — written to a new file and swapped in, as many apps do.
        try "second, from the Mac".write(to: copy, atomically: true, encoding: .utf8)
        try await driveSaves(files) { if case .saved = state.editing.first?.status { true } else { false } }
        #expect(try read(path) == "second, from the Mac")

        // The phone's copy changes behind the Mac's back; the next save keeps it.
        try put("changed on the phone itself", at: path)
        try "third".write(to: copy, atomically: true, encoding: .utf8)
        try await driveSaves(files) { if case .savedBeside = state.editing.first?.status { true } else { false } }
        #expect(try read(path) == "changed on the phone itself")
        #expect(try read(beside) == "third")
        #expect(state.editing.first?.phonePath == beside)

        files.stopEditing(session.id)
        #expect(state.editing.isEmpty)
    }

    // MARK: - Helpers

    private func put(_ text: String, at path: String) throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: local, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: local) }
        let connection = try ADBSyncConnection(serial: serial, useV2: true)
        defer { connection.close() }
        try connection.push(local, to: path) { _ in true }
    }

    private func read(_ path: String) throws -> String {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local) }
        let connection = try ADBSyncConnection(serial: serial, useV2: true)
        defer { connection.close() }
        try connection.pull(path, to: local) { _ in true }
        return try String(contentsOf: local, encoding: .utf8)
    }

    /// Steps the watcher the way its timer would, until `done`.
    private func driveSaves(_ files: PhoneFiles, until done: () -> Bool) async throws {
        for _ in 0 ..< 40 {
            files.checkForSaves()
            try await Task.sleep(for: .milliseconds(300))
            if done() { return }
        }
        Issue.record("the save never finished")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("timed out waiting")
    }
}
