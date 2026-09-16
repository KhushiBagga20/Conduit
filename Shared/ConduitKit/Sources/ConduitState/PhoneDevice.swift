//
//  PhoneDevice.swift
//  ConduitState
//
//  One physical phone, however many ways it is attached. A phone plugged in
//  over USB that also has Wireless debugging on is still one phone with two
//  transports — never two entries in the device list.
//

import ConduitProtocol
import Foundation

public nonisolated enum PhoneTransport: String, Sendable, Codable, Hashable, Comparable {
    case usb
    case wifi

    /// USB first: lower latency and no network in the way.
    public static func < (lhs: PhoneTransport, rhs: PhoneTransport) -> Bool {
        lhs == .usb && rhs == .wifi
    }
}

public nonisolated enum PhoneConnection: Sendable, Equatable {
    /// Known from before, not attached now.
    case disconnected
    /// Attached and usable.
    case connected(PhoneTransport)
    /// Attached, but the phone has not allowed this Mac to debug it yet.
    case unauthorized
    /// Attached, but adb reports it offline — usually mid-reconnect.
    case offline

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Reaching a phone over its own hotspot, where Wireless debugging cannot
/// go: Android turns that off whenever Wi-Fi is off.
public nonisolated enum HotspotAccess {
    /// adb's traditional port. The phone only listens on it once armed.
    public static let port: UInt16 = 5555
}

/// Conduit for Android on this phone, as seen over adb.
public nonisolated enum CompanionAppStatus: Sendable, Equatable {
    case unknown
    case notInstalled
    /// Installed. `canManageSettings` is true once this Mac has allowed it to
    /// change Wireless debugging and stay-awake settings.
    case installed(canManageSettings: Bool)
}

public nonisolated struct PhoneDevice: Identifiable, Sendable, Equatable {
    /// The phone's hardware serial — stable across USB and Wi-Fi.
    public let id: String
    public var name: String
    public var model: String?
    public var manufacturer: String?
    public var osVersion: String?
    public var connection: PhoneConnection
    /// Every transport the phone is currently attached by.
    public var transports: Set<PhoneTransport>
    public var battery: BatteryStatus?
    public var features: [FeatureID: Availability]
    public var lastSeen: Date?
    public var isPreferred: Bool
    public var companionApp: CompanionAppStatus
    /// The phone accepts adb connections over any network it joins, so it
    /// can be reached over its own hotspot.
    public var hotspotArmed: Bool
    /// This Mac is on the phone's hotspot and connected through it.
    public var isOverHotspot: Bool

    public init(id: String, name: String, model: String? = nil, manufacturer: String? = nil,
                osVersion: String? = nil, connection: PhoneConnection, transports: Set<PhoneTransport> = [],
                battery: BatteryStatus? = nil, features: [FeatureID: Availability] = [:],
                lastSeen: Date? = nil, isPreferred: Bool = false, companionApp: CompanionAppStatus = .unknown,
                hotspotArmed: Bool = false, isOverHotspot: Bool = false) {
        self.id = id
        self.name = name
        self.model = model
        self.manufacturer = manufacturer
        self.osVersion = osVersion
        self.connection = connection
        self.transports = transports
        self.battery = battery
        self.features = features
        self.lastSeen = lastSeen
        self.isPreferred = isPreferred
        self.companionApp = companionApp
        self.hotspotArmed = hotspotArmed
        self.isOverHotspot = isOverHotspot
    }

    /// "Samsung SM-S928B · Android 16", for secondary lines.
    public var detailLine: String {
        var parts: [String] = []
        if let model { parts.append([manufacturer?.capitalized, model].compactMap { $0 }.joined(separator: " ")) }
        if let osVersion { parts.append("Android \(osVersion)") }
        return parts.joined(separator: " · ")
    }
}
