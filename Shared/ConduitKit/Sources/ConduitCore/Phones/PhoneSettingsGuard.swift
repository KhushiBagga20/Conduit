//
//  PhoneSettingsGuard.swift
//  ConduitCore
//
//  Temporarily changes a phone setting and guarantees it is put back.
//
//  The original value is saved on the Mac before the phone is touched, so it
//  survives a stopped session, a lost connection, or Conduit quitting mid-way:
//  whatever is still pending is restored the next time that phone attaches.
//

import ConduitMedia
import Foundation

final class PhoneSettingsGuard {

    nonisolated enum Namespace: String, Sendable {
        case system, secure, global
    }

    private let adb: ADB
    private let defaults: UserDefaults
    private static let storageKey = "phoneSettingsRestore.v1"

    /// phoneID → "namespace/key" → original value (`null` when it was unset).
    private var pending: [String: [String: String]]

    init(adb: ADB, defaults: UserDefaults) {
        self.adb = adb
        self.defaults = defaults
        pending = defaults.dictionary(forKey: Self.storageKey) as? [String: [String: String]] ?? [:]
    }

    func hasPending(for phoneID: String) -> Bool {
        !(pending[phoneID]?.isEmpty ?? true)
    }

    /// Set `key` to `value`, remembering the original the first time.
    func override(_ namespace: Namespace, _ key: String, to value: String, phoneID: String, serial: String) async {
        let slot = "\(namespace.rawValue)/\(key)"
        let adb = self.adb

        if pending[phoneID]?[slot] == nil {
            let original = await Task.detached {
                adb.run(["-s", serial, "shell", "settings", "get", namespace.rawValue, key], timeout: 8)
            }.value
            guard original.ok else {
                CoreLog.devices.error("could not read setting \(slot); leaving it unchanged")
                return
            }
            pending[phoneID, default: [:]][slot] = original.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            save()
        }

        let result = await Task.detached {
            adb.run(["-s", serial, "shell", "settings", "put", namespace.rawValue, key, value], timeout: 8)
        }.value
        if !result.ok {
            CoreLog.devices.error("could not change setting \(slot)")
        }
    }

    /// Put back every setting still overridden on this phone.
    func restoreAll(phoneID: String, serial: String) async {
        guard let slots = pending[phoneID], !slots.isEmpty else { return }
        let adb = self.adb

        for (slot, original) in slots {
            let parts = slot.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let arguments = original == "null"
                ? ["-s", serial, "shell", "settings", "delete", parts[0], parts[1]]
                : ["-s", serial, "shell", "settings", "put", parts[0], parts[1], original]
            let result = await Task.detached { adb.run(arguments, timeout: 8) }.value
            if result.ok {
                pending[phoneID]?[slot] = nil
            } else {
                CoreLog.devices.error("could not restore setting \(slot); will retry when the phone is back")
            }
        }
        if pending[phoneID]?.isEmpty == true { pending[phoneID] = nil }
        save()
    }

    private func save() {
        defaults.set(pending, forKey: Self.storageKey)
    }
}
