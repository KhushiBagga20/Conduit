//
//  ConduitEngine.swift
//  ConduitCore
//
//  The single connection owner on the Mac.
//
//  It watches adb for phones, reconnects known phones over Wireless
//  debugging, runs mirroring sessions, applies clipboard policy, keeps the
//  activity log — and publishes all of it through ConduitStore, which is all
//  the menu bar and the workspace ever see.
//
//  Exactly one engine exists per app process. It is created by the app's
//  composition root and lives as long as the process: closing the workspace
//  window does not touch it.
//

import AppKit
import ConduitMedia
import ConduitProtocol
import ConduitState
import Foundation

public final class ConduitEngine: ConduitCommands {

    public let store = ConduitStore()

    private let adb: ADB?
    private let defaults: UserDefaults
    private var tracker: DeviceTracker?
    private let discovery = WirelessDiscovery()
    private var mirroring: MirroringController?

    private var attached: [String: AttachedTransport] = [:]
    private var known: [String: KnownPhone] = [:]
    private var propertiesInFlight: Set<String> = []
    private var connectAttempts: [String: Date] = [:]
    private var lastClipboardActivity = Date.distantPast
    private var started = false

    private enum Key {
        static let preferences = "preferences.v1"
        static let knownPhones = "knownPhones.v1"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        adb = ADB.locate()

        if let data = defaults.data(forKey: Key.preferences),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            store.preferences = saved
        }
        if let data = defaults.data(forKey: Key.knownPhones),
           let saved = try? JSONDecoder().decode([KnownPhone].self, from: data) {
            known = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }

        store.commands = self
        publishPhones()
    }

    /// Begin watching for phones. Safe to call more than once.
    public func start() {
        guard !started else { return }
        started = true

        guard let adb else {
            store.tools.adb = .missing
            store.record(ActivityEvent(kind: .error, title: "adb isn't installed",
                                       detail: "Install it with: brew install android-platform-tools"))
            return
        }
        store.tools.adb = .available(path: adb.path)

        let mirroring = MirroringController(adb: adb, state: store.mirroring)
        mirroring.targets = { [weak self] phoneID in
            guard let self else { return [] }
            return PhoneRegistry.targets(for: phoneID, attached: Array(self.attached.values))
        }
        mirroring.options = { [weak self] in self?.store.preferences.mirroring ?? MirroringOptions() }
        mirroring.onDeviceClipboard = { [weak self] text in self?.deviceClipboardChanged(text) }
        mirroring.record = { [weak self] event in self?.store.record(event) }
        self.mirroring = mirroring

        let tracker = DeviceTracker(adb: adb)
        tracker.onUpdate = { [weak self] devices in self?.devicesChanged(devices) }
        self.tracker = tracker

        discovery.onChange = { [weak self] endpoints in self?.wirelessEndpointsChanged(endpoints) }

        // Start the adb server off the main thread before anything spawns it
        // with a pipe attached.
        Task {
            await Task.detached { adb.startServer() }.value
            tracker.start()
            if store.preferences.autoConnectWireless { discovery.start() }
        }
    }

    // MARK: - ConduitCommands

    public func refreshPhones() {
        guard let adb else { return }
        Task {
            let output = await Task.detached { adb.run(["devices", "-l"], timeout: 10) }.value
            devicesChanged(ADBParsing.deviceList(output.stdout))
        }
    }

    public func selectPhone(_ phoneID: String) {
        guard store.phones.contains(where: { $0.id == phoneID }) else { return }
        store.activePhoneID = phoneID
    }

    public func setPreferredPhone(_ phoneID: String?) {
        updatePreferences { $0.preferredPhoneID = phoneID }
        publishPhones()
    }

    public func startMirroring(phoneID: String?) {
        guard let mirroring else {
            store.record(ActivityEvent(kind: .error, title: "Can't mirror without adb",
                                       detail: "Install it with: brew install android-platform-tools"))
            return
        }
        guard let id = phoneID ?? store.activePhoneID else { return }
        store.activePhoneID = id
        mirroring.start(phoneID: id)
    }

    public func stopMirroring() {
        mirroring?.stop()
    }

    public func restartMirroring() {
        mirroring?.restart()
    }

    public func updatePreferences(_ change: (inout Preferences) -> Void) {
        var preferences = store.preferences
        change(&preferences)
        guard preferences != store.preferences else { return }

        let wirelessChanged = preferences.autoConnectWireless != store.preferences.autoConnectWireless
        store.preferences = preferences
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Key.preferences)
        }

        if wirelessChanged, started, adb != nil {
            preferences.autoConnectWireless ? discovery.start() : discovery.stop()
        }
    }

    public func clearActivity() {
        store.activity.removeAll()
    }

    // MARK: - Devices

    private func devicesChanged(_ devices: [ADBParsing.Device]) {
        let before = store.phones

        var next: [String: AttachedTransport] = [:]
        for device in devices {
            var entry = AttachedTransport(device: device, properties: attached[device.serial]?.properties)
            if !device.isReady { entry.properties = nil }
            next[device.serial] = entry
        }
        attached = next

        for entry in next.values where entry.device.isReady && entry.properties == nil {
            loadProperties(serial: entry.device.serial)
        }

        publishPhones()
        recordConnectionChanges(from: before, to: store.phones)
        mirroring?.phonesChanged()
    }

    private func loadProperties(serial: String) {
        guard let adb, !propertiesInFlight.contains(serial) else { return }
        propertiesInFlight.insert(serial)

        Task {
            let properties = await Task.detached { adb.properties(of: serial) }.value
            propertiesInFlight.remove(serial)
            guard let properties, attached[serial] != nil else { return }

            let before = store.phones
            attached[serial]?.properties = properties
            remember(properties)
            publishPhones()
            recordConnectionChanges(from: before, to: store.phones)
            mirroring?.phonesChanged()
        }
    }

    private func remember(_ properties: ADBParsing.PhoneProperties) {
        known[properties.hardwareSerial] = KnownPhone(
            id: properties.hardwareSerial, name: properties.name, model: properties.model,
            manufacturer: properties.manufacturer, osVersion: properties.osVersion, lastSeen: Date())
        if let data = try? JSONEncoder().encode(Array(known.values)) {
            defaults.set(data, forKey: Key.knownPhones)
        }
    }

    private func publishPhones() {
        store.phones = PhoneRegistry.phones(attached: Array(attached.values), known: known,
                                            preferredID: store.preferences.preferredPhoneID)

        // Keep the user's choice while it exists; otherwise prefer the
        // preferred phone, then any connected phone, then anything known.
        let ids = Set(store.phones.map(\.id))
        if let active = store.activePhoneID, ids.contains(active),
           store.phones.first(where: { $0.id == active })?.connection.isConnected == true
            || store.connectedPhones.isEmpty {
            return
        }
        store.activePhoneID = store.connectedPhones.first(where: \.isPreferred)?.id
            ?? store.connectedPhones.first?.id
            ?? store.phones.first(where: \.isPreferred)?.id
            ?? store.phones.first?.id
    }

    private func recordConnectionChanges(from before: [PhoneDevice], to after: [PhoneDevice]) {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        for phone in after {
            let previous = old[phone.id]?.connection
            guard previous != phone.connection else { continue }
            switch phone.connection {
            case .connected(let transport):
                // A phone that only changed transport is not news.
                if case .connected = previous { continue }
                store.record(ActivityEvent(kind: .phoneConnected, title: "\(phone.name) connected",
                                           detail: transport == .usb ? "Over USB" : "Over Wi-Fi"))
            case .unauthorized:
                store.record(ActivityEvent(kind: .permissionRequired, title: "Allow debugging on \(phone.name)",
                                           detail: "Tap Allow on the phone so this Mac can connect."))
            case .disconnected where previous?.isConnected == true:
                store.record(ActivityEvent(kind: .phoneDisconnected, title: "\(phone.name) disconnected"))
            default:
                break
            }
        }
    }

    // MARK: - Wireless debugging

    private func wirelessEndpointsChanged(_ endpoints: [WirelessEndpoint]) {
        guard let adb, store.preferences.autoConnectWireless else { return }

        for endpoint in endpoints {
            // Only phones this Mac already knows: someone else's phone
            // advertising on the same network is not ours to connect to.
            guard let phoneID = endpoint.hardwareSerial, known[phoneID] != nil else { continue }
            guard !attached.values.contains(where: { $0.phoneID == phoneID && $0.transport == .wifi && $0.device.isReady })
            else { continue }

            let key = "\(endpoint.host):\(endpoint.port)"
            if let last = connectAttempts[key], Date().timeIntervalSince(last) < 30 { continue }
            connectAttempts[key] = Date()

            CoreLog.engine.info("connecting to a known phone over Wireless debugging")
            let host = endpoint.host, port = endpoint.port
            Task.detached { _ = adb.connect(host: host, port: port) }
        }
    }

    // MARK: - Clipboard

    private func deviceClipboardChanged(_ text: String) {
        guard store.preferences.clipboardSync, !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // One activity entry per burst of copies, and never the text itself.
        if Date().timeIntervalSince(lastClipboardActivity) > 10 {
            lastClipboardActivity = Date()
            store.record(ActivityEvent(kind: .clipboardSynced, title: "Clipboard synced from phone"))
        }
    }
}
