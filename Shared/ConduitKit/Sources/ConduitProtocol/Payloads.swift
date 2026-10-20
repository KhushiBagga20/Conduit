//
//  Payloads.swift
//  ConduitProtocol
//
//  Typed payload objects shared by several messages.
//  Spec: Shared/Protocol/README.md §6.
//

import Foundation

public enum Platform: String, Codable, Sendable {
    case android
    case macos
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var model: String?
    public var manufacturer: String?
    public var platform: Platform
    public var osVersion: String?
    public var appVersion: String?

    public init(id: String, name: String, model: String? = nil, manufacturer: String? = nil,
                platform: Platform, osVersion: String? = nil, appVersion: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.manufacturer = manufacturer
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
    }
}

public struct BatteryStatus: Codable, Sendable, Equatable {
    /// 0–100.
    public var level: Int
    public var charging: Bool

    public init(level: Int, charging: Bool) {
        self.level = min(max(level, 0), 100)
        self.charging = charging
    }
}

public enum NetworkType: String, Codable, Sendable {
    case wifi
    case cellular
    case ethernet
    case none
}

public struct NetworkStatus: Codable, Sendable, Equatable {
    public var type: NetworkType

    public init(type: NetworkType) {
        self.type = type
    }
}

/// One notification showing on the phone — Shared/Protocol/README.md §6.
///
/// It carries only what the Mac shows. A notification the phone marks
/// private arrives `redacted`, with no title or text at all, so there is
/// nothing here to leak even in memory.
public struct PhoneNotification: Codable, Sendable, Equatable, Identifiable {
    /// The phone's own key for it, used to dismiss or open it again.
    public var key: String
    public var appID: String
    public var appName: String
    public var title: String?
    public var text: String?
    /// Milliseconds since the Unix epoch, from the phone's clock.
    public var postedAt: UInt64
    /// Whether the phone will let it be dismissed from here.
    public var clearable: Bool
    /// The phone held back the contents because the app marked them private.
    public var redacted: Bool

    public var id: String { key }

    public init(key: String, appID: String, appName: String, title: String? = nil, text: String? = nil,
                postedAt: UInt64, clearable: Bool = true, redacted: Bool = false) {
        self.key = key
        self.appID = appID
        self.appName = appName
        self.title = title
        self.text = text
        self.postedAt = postedAt
        self.clearable = clearable
        self.redacted = redacted
    }
}

public struct DeviceSnapshot: Codable, Sendable, Equatable {
    public var device: DeviceInfo
    public var battery: BatteryStatus?
    public var network: NetworkStatus?
    public var locked: Bool?
    /// Keyed by FeatureID raw value; unknown features are kept, not dropped.
    public var features: [String: Availability]

    public init(device: DeviceInfo, battery: BatteryStatus? = nil, network: NetworkStatus? = nil,
                locked: Bool? = nil, features: [String: Availability] = [:]) {
        self.device = device
        self.battery = battery
        self.network = network
        self.locked = locked
        self.features = features
    }
}
