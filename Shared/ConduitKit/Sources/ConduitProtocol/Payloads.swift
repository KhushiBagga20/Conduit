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
