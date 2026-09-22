//
//  Link.swift
//  ConduitState
//
//  What the interfaces show about Conduit Link: whether this Mac is
//  listening, which phones are paired, and a phone waiting to be compared
//  against six digits.
//

import Foundation

/// A phone this Mac has paired with.
public nonisolated struct LinkedPhone: Identifiable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var isConnected: Bool
    public var lastSeen: Date

    public init(id: String, name: String, isConnected: Bool, lastSeen: Date) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.lastSeen = lastSeen
    }
}

/// A phone in the middle of pairing. The same six digits appear on both
/// devices, and both people have to agree before either side trusts the other.
public nonisolated struct LinkPairingRequest: Sendable, Equatable {
    public let code: String
    public let deviceName: String

    public init(code: String, deviceName: String) {
        self.code = code
        self.deviceName = deviceName
    }
}

/// Asking a phone for its hotspot over Bluetooth, for when this Mac is offline.
public nonisolated enum HotspotRequestStatus: Sendable, Equatable {
    case idle
    case asking
    /// A phone took the request; it shows a notification to turn the hotspot on.
    case asked(Date)
    case noPhoneNearby
    case bluetoothOff
    case bluetoothDenied
    case failed(String)
}

/// Sending the web link on this Mac's clipboard to a linked phone. Only the
/// site's name is kept, never the link.
public nonisolated enum LinkSendStatus: Sendable, Equatable {
    case idle
    case sending(site: String)
    /// The phone took the link and shows a notification to open it.
    case sent(site: String, phone: String)
    case noLinkOnClipboard
    case noPhoneConnected
    case failed(String)
}

@Observable
public final class LinkState {

    /// The port phones dial, once the listener is up.
    public package(set) var port: UInt16?

    public var isListening: Bool { port != nil }

    /// Whether phones can find this Mac by themselves. macOS blocks the
    /// Bonjour advert until Conduit is allowed on the local network.
    public package(set) var isAdvertising = false

    /// True only while the person is adding a phone: this Mac pairs with a
    /// phone it does not know at no other time.
    public package(set) var isPairingOpen = false

    public package(set) var pairingRequest: LinkPairingRequest?

    public package(set) var phones: [LinkedPhone] = []

    public package(set) var hotspotRequest: HotspotRequestStatus = .idle

    public package(set) var linkSend: LinkSendStatus = .idle

    /// Whether a linked phone is connected right now.
    public var hasConnectedPhone: Bool { phones.contains(where: \.isConnected) }

    package init() {}
}
