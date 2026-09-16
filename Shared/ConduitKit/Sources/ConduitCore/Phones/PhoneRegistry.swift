//
//  PhoneRegistry.swift
//  ConduitCore
//
//  Turns adb transports into phones.
//
//  adb thinks in transports: a USB serial, a `host:port`, an mDNS service
//  name. People think in phones. This file groups transports by hardware
//  serial, merges in phones remembered from earlier sessions, and decides
//  what each feature can honestly offer right now. Pure logic, unit tested.
//

import ConduitProtocol
import ConduitState
import Foundation

/// One adb transport and what is known about the phone behind it.
nonisolated struct AttachedTransport: Sendable, Equatable {
    let device: ADBParsing.Device
    var properties: ADBParsing.PhoneProperties?
    /// The phone this transport belongs to when Conduit connected it itself
    /// and so knows before the phone's properties have loaded.
    var identityHint: String?

    init(device: ADBParsing.Device, properties: ADBParsing.PhoneProperties? = nil, identityHint: String? = nil) {
        self.device = device
        self.properties = properties
        self.identityHint = identityHint
    }

    var transport: PhoneTransport { device.transport }

    /// Hardware serial when known, else the best hint available.
    var phoneID: String {
        properties?.hardwareSerial
            ?? identityHint
            ?? ADBParsing.hardwareSerialHint(fromSerial: device.serial)
            ?? device.serial
    }

    /// A ready Wi-Fi transport nobody can yet tie to a phone.
    var isAnonymousWiFi: Bool {
        device.isReady && transport == .wifi && properties == nil && identityHint == nil
            && ADBParsing.hardwareSerialHint(fromSerial: device.serial) == nil
    }
}

/// What Conduit remembers about a phone between launches. Nothing more.
nonisolated struct KnownPhone: Codable, Sendable, Equatable {
    let id: String
    var name: String
    var model: String?
    var manufacturer: String?
    var osVersion: String?
    var lastSeen: Date
    /// The port adb's TCP mode was armed on, so the phone can be reached
    /// over its own hotspot. Nil when it was never armed or was turned off.
    var hotspotPort: UInt16?
}

enum PhoneRegistry {

    static func phones(attached: [AttachedTransport], known: [String: KnownPhone],
                       preferredID: String?, companionApps: [String: CompanionAppStatus] = [:],
                       gateway: String? = nil, now: Date = Date()) -> [PhoneDevice] {
        var phones: [String: PhoneDevice] = [:]

        // A Wi-Fi transport known only as host:port is anonymous until its
        // properties load (a fraction of a second). Listing it meanwhile would
        // flash a second copy of a phone that is already on USB. Transports
        // that cannot load properties — unauthorised, offline — stay visible.
        let identifiable = attached.filter { !$0.isAnonymousWiFi }

        for (id, group) in Dictionary(grouping: identifiable, by: \.phoneID) {
            let ready = group.filter { $0.device.isReady }
            let properties = group.compactMap(\.properties).first
            let remembered = known[id]
            let transports = Set(ready.map(\.transport))

            let connection: PhoneConnection
            if let best = transports.sorted().first {
                connection = .connected(best)
            } else if group.contains(where: { $0.device.state == "unauthorized" }) {
                connection = .unauthorized
            } else {
                connection = .offline
            }

            phones[id] = PhoneDevice(
                id: id,
                name: properties?.name ?? remembered?.name ?? group.first?.device.model ?? "Android phone",
                model: properties?.model ?? remembered?.model ?? group.first?.device.model,
                manufacturer: properties?.manufacturer ?? remembered?.manufacturer,
                osVersion: properties?.osVersion ?? remembered?.osVersion,
                connection: connection,
                transports: transports,
                features: features(connected: connection.isConnected,
                                   osVersion: properties?.osVersion ?? remembered?.osVersion),
                lastSeen: connection.isConnected ? now : remembered?.lastSeen,
                isPreferred: id == preferredID,
                companionApp: companionApps[id] ?? .unknown,
                hotspotArmed: remembered?.hotspotPort != nil,
                isOverHotspot: gateway.map { router in ready.contains { $0.device.serial.hasPrefix("\(router):") } } ?? false)
        }

        for (id, remembered) in known where phones[id] == nil {
            phones[id] = PhoneDevice(
                id: id, name: remembered.name, model: remembered.model,
                manufacturer: remembered.manufacturer, osVersion: remembered.osVersion,
                connection: .disconnected,
                features: features(connected: false, osVersion: remembered.osVersion),
                lastSeen: remembered.lastSeen,
                isPreferred: id == preferredID,
                hotspotArmed: remembered.hotspotPort != nil)
        }

        // Connected first, then preferred, then most recently seen.
        return phones.values.sorted { a, b in
            if a.connection.isConnected != b.connection.isConnected { return a.connection.isConnected }
            if a.isPreferred != b.isPreferred { return a.isPreferred }
            return (a.lastSeen ?? .distantPast) > (b.lastSeen ?? .distantPast)
        }
    }

    /// Transports that can carry a session for this phone, best first.
    static func targets(for phoneID: String, attached: [AttachedTransport]) -> [MirroringController.Target] {
        attached
            .filter { $0.phoneID == phoneID && $0.device.isReady }
            .sorted { $0.transport < $1.transport }
            .map { MirroringController.Target(serial: $0.device.serial, transport: $0.transport) }
    }

    /// What each feature can offer today. Features that need the Conduit
    /// Android app, or are not built yet, say so instead of pretending.
    static func features(connected: Bool, osVersion: String?) -> [FeatureID: Availability] {
        let major = osVersion.flatMap { Int($0.split(separator: ".").first ?? "") }
        let overADB: Availability = connected ? .available : .requiresSetup

        return [
            .mirroring: overADB,
            .remoteInput: overADB,
            .clipboard: overADB,
            // scrcpy audio capture needs Android 11.
            .audio: major.map { $0 >= 11 } == false ? .unsupported : overADB,
            // scrcpy's camera source needs Android 12; the Conduit interface for it is not built yet.
            .camera: major.map { $0 >= 12 } == false ? .unsupported : .planned,
            .trackpad: .planned,
            .calls: .planned,
            .links: .planned,
            .files: .planned,
            .notifications: .planned,
            .findMac: .planned,
        ]
    }
}
