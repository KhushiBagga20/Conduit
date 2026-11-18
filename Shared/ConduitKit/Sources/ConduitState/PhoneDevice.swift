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

/// What this Mac last learned over the cable about reaching the phone over
/// Wi-Fi: whether Wireless debugging is on, where it listens, and where the
/// phone is on its network.
public nonisolated struct WirelessInfo: Sendable, Equatable, Codable {
    public var debuggingOn: Bool
    public var address: String?
    /// Wireless debugging's port. It moves whenever Wireless debugging
    /// restarts, so it is a first guess, not a promise.
    public var port: UInt16?
    public var checked: Date
    /// Whether this Mac could open that port while the phone was plugged in
    /// and on the same network. False means the network keeps them apart.
    public var reachable: Bool?
    /// The phone's hotspot passes its Wi-Fi on, and it stays on that Wi-Fi
    /// with Wireless debugging still listening. Nil where unknown.
    public var wifiSharing: Bool?
    /// The phone's address on its own hotspot, last time it was on.
    public var hotspotAddress: String?

    public init(debuggingOn: Bool, address: String?, port: UInt16?, checked: Date, reachable: Bool? = nil,
                wifiSharing: Bool? = nil, hotspotAddress: String? = nil) {
        self.debuggingOn = debuggingOn
        self.address = address
        self.port = port
        self.checked = checked
        self.reachable = reachable
        self.wifiSharing = wifiSharing
        self.hotspotAddress = hotspotAddress
    }
}

/// Whether the phone can be used without the cable right now, and if not,
/// the reason a person can act on.
public nonisolated enum WifiReachability: Sendable, Equatable {
    /// Not plugged in since Conduit began checking, so nothing is known yet.
    case unknown
    case connected
    case notOnWiFi
    case debuggingOff
    /// Switched on, but not listening: Android waits for this Wi-Fi network
    /// to be allowed on the phone before it starts.
    case waitingForApproval
    /// Phone and Mac look to be on different networks.
    case differentNetwork(phone: String, mac: String)
    /// On the same network; connecting.
    case trying
    /// On the same network, but nothing gets through — usually a network
    /// that keeps its devices from reaching each other.
    case unreachable
    /// Measured while plugged in: on the same network, and this Mac could
    /// not reach the phone's open port. The network keeps its devices apart.
    case keptApart
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
    /// The phone's hotspot passes its Wi-Fi on, so the phone stays on that
    /// Wi-Fi — and reachable — while the Mac uses its hotspot.
    public var sharesWiFi: Bool = false
    /// Whether it works without the cable, and why not.
    public var wifi: WifiReachability = .unknown

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
