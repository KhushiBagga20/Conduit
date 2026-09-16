//
//  PhoneTouchGuard.swift
//  ConduitCore
//
//  Makes the phone ignore its own touchscreen while its screen is off and
//  mirroring continues.
//
//  MEASURED on a Galaxy S24 Ultra: turning the panel off — scrcpy's display
//  power, or Android 15's `cmd display power-off` — leaves the touchscreen
//  live, and adb cannot disable an input device (that needs a signature
//  permission). Conduit for Android has an accessibility service that
//  swallows touches from the phone's own screen. Input the Mac injects never
//  passes through accessibility, so the Mac keeps full control.
//
//  The service runs on a lease that this guard renews while the screen is
//  off. If renewals stop — Conduit quits, the Mac sleeps, the phone drops
//  off — the lease runs out and the service turns itself off. The secure
//  settings that switch it on are changed through PhoneSettingsGuard, so they
//  are put back even after a crash.
//

import ConduitMedia
import ConduitState
import Foundation

@MainActor
final class PhoneTouchGuard {

    nonisolated static let service = "com.khushi.conduit/com.khushi.conduit.guard.TouchGuardService"
    nonisolated static let leaseReceiver = "com.khushi.conduit/com.khushi.conduit.guard.TouchGuardLease"
    nonisolated static let leaseMilliseconds = 60_000
    static let renewalInterval: Duration = .seconds(20)

    private let adb: ADB
    private let settings: PhoneSettingsGuard
    private var task: Task<Void, Never>?
    private var generation = 0

    /// Reports progress for the phone being guarded.
    var onStatus: (TouchGuardStatus) -> Void = { _ in }

    init(adb: ADB, settings: PhoneSettingsGuard) {
        self.adb = adb
        self.settings = settings
    }

    /// Turn the guard on and keep it on until `stop()`. Calling it again
    /// (after mirroring resumes on a new server) re-checks and carries on.
    func start(phoneID: String, serial: String, companionApp: CompanionAppStatus?) {
        task?.cancel()
        generation += 1
        let gen = generation
        onStatus(.starting)
        task = Task { [weak self] in
            await self?.run(phoneID: phoneID, serial: serial, companionApp: companionApp, generation: gen)
        }
    }

    /// Stop renewing and end the guard now. The caller restores settings.
    func stop(serial: String?) {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        generation += 1
        if let serial {
            let adb = self.adb
            Task.detached { _ = Self.renewLease(adb: adb, serial: serial, milliseconds: 0) }
        }
    }

    // MARK: - Private

    private func run(phoneID: String, serial: String, companionApp: CompanionAppStatus?, generation gen: Int) async {
        let adb = self.adb

        // Arming the lease also tells us whether this phone's Conduit for
        // Android has the guard at all.
        let first = await Task.detached { Self.renewLease(adb: adb, serial: serial, milliseconds: Self.leaseMilliseconds) }.value
        guard gen == generation else { return }

        switch first {
        case .replied("guarding"), .replied("armed"):
            break
        case .replied("unsupported"):
            report(.unavailable("Ignoring touches on the phone needs Android 13 or later. Touch vibration is paused instead."), gen)
            return
        case .unreachable:
            report(.unavailable("The phone didn't answer, so it still responds to touch. Touch vibration is paused instead."), gen)
            return
        case .replied, .noGuard:
            let install = companionApp == .notInstalled ? "Install" : "Update"
            report(.unavailable("\(install) Conduit for Android on the phone so it ignores touches while its screen is off. Touch vibration is paused meanwhile."), gen)
            return
        }

        if first != .replied("guarding") {
            await enableService(phoneID: phoneID, serial: serial)
        }

        // The phone binds the service within a moment of the setting changing.
        var guarding = first == .replied("guarding")
        for _ in 0 ..< 12 where !guarding {
            try? await Task.sleep(for: .milliseconds(250))
            guard gen == generation else { return }
            let reply = await Task.detached { Self.renewLease(adb: adb, serial: serial, milliseconds: Self.leaseMilliseconds) }.value
            guarding = reply == .replied("guarding")
        }
        guard gen == generation else { return }
        guard guarding else {
            CoreLog.devices.error("touch guard did not start on the phone")
            report(.unavailable("The phone didn't start ignoring touches. Touch vibration is paused instead."), gen)
            return
        }
        report(.active, gen)

        while gen == generation {
            try? await Task.sleep(for: Self.renewalInterval)
            guard gen == generation else { return }
            let reply = await Task.detached { Self.renewLease(adb: adb, serial: serial, milliseconds: Self.leaseMilliseconds) }.value
            guard gen == generation else { return }
            switch reply {
            case .replied("guarding"):
                continue
            case .replied, .noGuard:
                // Stood down on the phone — the power button was pressed, or
                // the app restarted. Touches work there now; leave it so.
                report(.unavailable("Touches on the phone work again: the phone ended the touch guard, usually because its power button was pressed."), gen)
                return
            case .unreachable:
                // The phone may be switching transports. The lease covers a
                // few missed renewals; after that the phone ends it.
                continue
            }
        }
    }

    private func enableService(phoneID: String, serial: String) async {
        let adb = self.adb
        let current = await Task.detached {
            adb.run(["-s", serial, "shell", "settings", "get", "secure", "enabled_accessibility_services"], timeout: 8)
        }.value
        guard current.ok else { return }

        let services = Self.enabledServices(adding: Self.service, to: current.stdout)
        await settings.override(.secure, "enabled_accessibility_services", to: services, phoneID: phoneID, serial: serial)
        await settings.override(.secure, "accessibility_enabled", to: "1", phoneID: phoneID, serial: serial)
    }

    private func report(_ status: TouchGuardStatus, _ gen: Int) {
        guard gen == generation else { return }
        onStatus(status)
    }

    /// `enabled_accessibility_services` with `service` added, keeping every
    /// service the person already uses.
    nonisolated static func enabledServices(adding service: String, to setting: String) -> String {
        let current = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        var services = current == "null" ? [] : current.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if !services.contains(service) { services.append(service) }
        return services.joined(separator: ":")
    }

    nonisolated enum LeaseReply: Equatable, Sendable {
        /// The guard answered: `guarding`, `armed`, `released` or `unsupported`.
        case replied(String)
        /// The broadcast went through but nothing answered — no guard in
        /// this version of Conduit for Android, or no app at all.
        case noGuard
        /// adb could not reach the phone.
        case unreachable
    }

    /// Renew the lease, or end it with 0.
    nonisolated private static func renewLease(adb: ADB, serial: String, milliseconds: Int) -> LeaseReply {
        let output = adb.run(["-s", serial, "shell", "am", "broadcast", "-f", "32", "-n", leaseReceiver,
                              "--el", "for_ms", String(milliseconds)], timeout: 8)
        guard output.ok, output.stdout.contains("Broadcast completed") else { return .unreachable }
        return ADBParsing.broadcastResultData(output.stdout).map(LeaseReply.replied) ?? .noGuard
    }
}
