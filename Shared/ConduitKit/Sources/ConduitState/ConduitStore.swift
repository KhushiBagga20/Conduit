//
//  ConduitStore.swift
//  ConduitState
//
//  The seam between Conduit's interfaces and its connection owner.
//
//      menu bar ─┐                     ┌─ ConduitCore (the owner)
//                ├─ observe ConduitStore ┤
//      workspace ┘   call ConduitCommands └─ mutates the store
//
//  Interfaces read the store and call commands; they never touch sockets,
//  adb or sessions. Every stored property is `package(set)`: inside
//  ConduitKit the owner can change it, and outside — in the app — it is
//  read-only. That keeps "one connection owner" a compile-time rule.
//
//  When the owner moves into a helper process, an XPC-backed object
//  implements ConduitCommands and fills a local ConduitStore from snapshots;
//  neither interface changes.
//

import ConduitProtocol
import Foundation
import Observation

@MainActor
public protocol ConduitCommands: AnyObject {
    /// Re-read attached devices now instead of waiting for the next change.
    func refreshPhones()
    /// Choose which phone the interfaces act on.
    func selectPhone(_ phoneID: String)
    /// The phone Conduit prefers when several are available; nil for none.
    func setPreferredPhone(_ phoneID: String?)

    /// Start mirroring the given phone, or the active phone when nil.
    func startMirroring(phoneID: String?)
    func stopMirroring()
    /// Restart the server and the session after a failure.
    func restartMirroring()

    /// Put the Mac's clipboard text on the phone's clipboard. Needs an
    /// active mirroring session.
    func sendMacClipboardToPhone()

    /// Turn the phone's own screen off or on while mirroring continues.
    func setPhoneScreen(on: Bool)

    /// Let Conduit for Android change Wireless debugging and stay-awake
    /// settings on this phone. Granted over adb; the user asks for it.
    func allowCompanionSettingsControl(phoneID: String)

    /// Let this phone be reached over its own hotspot, where Wireless
    /// debugging cannot go, and stop again.
    func prepareHotspotConnection(phoneID: String)
    func stopHotspotConnection(phoneID: String)

    func updatePreferences(_ change: (inout Preferences) -> Void)
    func clearActivity()
}

public nonisolated struct Preferences: Codable, Sendable, Equatable {
    public var preferredPhoneID: String?
    public var mirroring = MirroringOptions()
    /// Copy on the phone lands on the Mac pasteboard while mirroring.
    public var clipboardSync = true
    /// Reconnect known phones over Wireless debugging when they appear.
    public var autoConnectWireless = true

    public init() {}
}

public nonisolated struct ToolStatus: Sendable, Equatable {
    public enum ADBState: Sendable, Equatable {
        case checking
        case available(path: String)
        case missing
    }

    public var adb: ADBState = .checking

    public init() {}
}

@Observable
public final class ConduitStore {

    public package(set) var phones: [PhoneDevice] = []
    public package(set) var activePhoneID: String?
    public let mirroring = MirroringState()
    public package(set) var activity: [ActivityEvent] = []
    public package(set) var tools = ToolStatus()
    public package(set) var preferences = Preferences()

    /// The owner. Weak: the owner holds the store, not the other way round.
    public package(set) weak var commands: (any ConduitCommands)?

    public var activePhone: PhoneDevice? {
        phones.first { $0.id == activePhoneID }
    }

    public var connectedPhones: [PhoneDevice] {
        phones.filter { $0.connection.isConnected }
    }

    package init() {}

    // MARK: Owner-side helpers

    /// Newest first, capped so a long session cannot grow without bound.
    package func record(_ event: ActivityEvent) {
        activity.insert(event, at: 0)
        if activity.count > Self.activityLimit {
            activity.removeLast(activity.count - Self.activityLimit)
        }
    }

    static let activityLimit = 200
}
