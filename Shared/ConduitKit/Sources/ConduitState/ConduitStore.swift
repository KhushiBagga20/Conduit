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

    /// Ask linked phones over Bluetooth to turn their hotspot on.
    func requestPhoneHotspot()

    /// Send the web link on this Mac's clipboard to the linked phone.
    func sendLinkToPhone()

    /// Stop the sound a phone started when it went looking for this Mac.
    func stopRinging()

    /// Dismiss a notification on the phone, as swiping it away would.
    func dismissNotification(key: String)

    /// Ask the phone to open what a notification points at.
    func openNotification(key: String)

    /// Forget what this Mac is showing, leaving the phone's own alone.
    func clearNotifications()

    /// Ask the phone again for what it is showing.
    func refreshNotifications()

    /// Read the clipboard once at the person's request, which makes macOS
    /// list Conduit where Always Allow can be chosen.
    func requestMacClipboardAccess()

    /// Look again at what macOS allows and which ways the clipboard can flow.
    func refreshClipboardStatus()

    /// Ask macOS for the Accessibility permission the phone's trackpad needs.
    func requestTrackpadPermission()

    /// Look again at whether macOS grants it.
    func refreshTrackpadPermission()

    /// Conduit Link: pairing with a phone, and forgetting one.
    func openLinkPairing()
    func closeLinkPairing()
    func confirmLinkPairing()
    func rejectLinkPairing()
    func forgetLinkedPhone(id: String)

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
    /// When this Mac goes offline, ask a linked phone over Bluetooth to turn
    /// its hotspot on.
    public var askPhoneForHotspot = true
    /// Open links a linked phone shares, in the default browser.
    public var openLinksFromPhone = true
    /// Let a linked phone drive this Mac's pointer from its trackpad screen.
    public var phoneTrackpad = true
    /// How far the pointer travels per point of finger movement, 0.5–3.
    public var trackpadSensitivity = 1.6
    /// Content follows the fingers, as macOS scrolls by default.
    public var naturalScrolling = true
    /// The phone buzzes when a click lands on the Mac.
    public var trackpadHaptics = true
    /// Show a phone notification on this Mac as it arrives.
    public var notificationBanners = true

    public init() {}

    /// Every field is optional on the way in, so preferences saved by an
    /// older build keep their values instead of failing to decode and
    /// silently resetting to defaults.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        preferredPhoneID = try saved.decodeIfPresent(String.self, forKey: .preferredPhoneID)
        mirroring = try saved.decodeIfPresent(MirroringOptions.self, forKey: .mirroring) ?? MirroringOptions()
        clipboardSync = try saved.decodeIfPresent(Bool.self, forKey: .clipboardSync) ?? true
        autoConnectWireless = try saved.decodeIfPresent(Bool.self, forKey: .autoConnectWireless) ?? true
        askPhoneForHotspot = try saved.decodeIfPresent(Bool.self, forKey: .askPhoneForHotspot) ?? true
        openLinksFromPhone = try saved.decodeIfPresent(Bool.self, forKey: .openLinksFromPhone) ?? true
        phoneTrackpad = try saved.decodeIfPresent(Bool.self, forKey: .phoneTrackpad) ?? true
        trackpadSensitivity = try saved.decodeIfPresent(Double.self, forKey: .trackpadSensitivity) ?? 1.6
        naturalScrolling = try saved.decodeIfPresent(Bool.self, forKey: .naturalScrolling) ?? true
        trackpadHaptics = try saved.decodeIfPresent(Bool.self, forKey: .trackpadHaptics) ?? true
        notificationBanners = try saved.decodeIfPresent(Bool.self, forKey: .notificationBanners) ?? true
    }
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
    public let link = LinkState()
    public let clipboard = ClipboardState()
    public package(set) var activity: [ActivityEvent] = []
    /// What is showing on the linked phone, newest first. In memory only:
    /// Conduit never writes a notification down.
    public package(set) var notifications: [PhoneNotification] = []
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

    /// The phone posted one, or sent what it is already showing.
    package func show(_ notification: PhoneNotification) {
        notifications.removeAll { $0.key == notification.key }
        notifications.insert(notification, at: 0)
        if notifications.count > Self.notificationLimit {
            notifications.removeLast(notifications.count - Self.notificationLimit)
        }
        notifications.sort { $0.postedAt > $1.postedAt }
    }

    package func removeNotification(key: String) {
        notifications.removeAll { $0.key == key }
    }

    package func removeAllNotifications() {
        notifications.removeAll()
    }

    static let activityLimit = 200
    static let notificationLimit = 100
}
