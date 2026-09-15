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
    private var reconnector: WirelessReconnector?
    private var mirroring: MirroringController?
    private var settingsGuard: PhoneSettingsGuard?

    private var attached: [String: AttachedTransport] = [:]
    private var known: [String: KnownPhone] = [:]
    private var propertiesInFlight: Set<String> = []
    private var propertyFailures: [String: Int] = [:]
    private var companionApps: [String: CompanionAppStatus] = [:]
    /// Wi-Fi transports Conduit connected itself, by serial, and the phone
    /// each belongs to — so they are usable before properties load.
    private var wifiIdentities: [String: String] = [:]
    /// Phones that connected before their name was known. Announced once
    /// their properties load, so activity never says "SM S928B connected".
    private var unannouncedConnections: [String: PhoneTransport] = [:]
    /// Phones whose current connection has been announced, so a transport
    /// that resolves into an already-connected phone is not news.
    private var announcedPhones: Set<String> = []
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
        mirroring.onSessionEnded = { [weak self] phoneID in self?.mirroringEnded(phoneID: phoneID) }
        mirroring.onSessionResumed = { [weak self] in self?.reapplyPhoneScreenState() }
        self.mirroring = mirroring
        settingsGuard = PhoneSettingsGuard(adb: adb, defaults: defaults)

        let tracker = DeviceTracker(adb: adb)
        tracker.onUpdate = { [weak self] devices in self?.devicesChanged(devices) }
        self.tracker = tracker

        let reconnector = WirelessReconnector(adb: adb, discovery: discovery)
        reconnector.isEnabled = { [weak self] in self?.store.preferences.autoConnectWireless ?? false }
        reconnector.isKnownPhone = { [weak self] id in self?.known[id] != nil }
        reconnector.wifiTransports = { [weak self] id in
            self?.attached.values.filter { $0.phoneID == id && $0.transport == .wifi }.map(\.device) ?? []
        }
        reconnector.isMirroring = { [weak self] in self?.store.mirroring.status.isActive ?? false }
        reconnector.record = { [weak self] event in self?.store.record(event) }
        reconnector.onConnected = { [weak self] serial, phoneID in self?.wifiTransportConnected(serial, phoneID: phoneID) }
        self.reconnector = reconnector

        discovery.onChange = { [weak self] _ in self?.reconnector?.evaluate() }
        discovery.onBlocked = { [weak self] _ in
            self?.store.record(ActivityEvent(
                kind: .permissionRequired,
                title: "Allow Local Network access",
                detail: "Conduit can't look for phones on Wi-Fi. Turn it on in System Settings → Privacy & Security → Local Network."))
        }

        // Start the adb server off the main thread before anything spawns it
        // with a pipe attached.
        Task {
            await Task.detached { adb.startServer() }.value
            tracker.start()
            if store.preferences.autoConnectWireless {
                discovery.start()
                reconnector.start()
            }
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

    public func sendMacClipboardToPhone() {
        guard let session = store.mirroring.session, session.control.state == .connected else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        session.input.sendClipboard(text, paste: false)
        store.record(ActivityEvent(kind: .clipboardSynced, title: "Clipboard sent to phone"))
    }

    public func setPhoneScreen(on: Bool) {
        guard let session = store.mirroring.session, session.control.state == .connected,
              let phoneID = store.mirroring.phoneID, let serial = mirroring?.currentSerial else { return }

        if on {
            session.input.setDisplayPower(on: true)
            store.mirroring.isPhoneScreenOff = false
            store.record(ActivityEvent(kind: .mirroringStarted, title: "Phone screen turned on"))
            Task { await settingsGuard?.restoreAll(phoneID: phoneID, serial: serial) }
        } else {
            store.mirroring.isPhoneScreenOff = true
            session.input.setDisplayPower(on: false)
            store.record(ActivityEvent(
                kind: .mirroringStopped, title: "Phone screen turned off",
                detail: "Mirroring continues. This phone keeps its touchscreen active, so touch vibration is paused until the screen is back on."))
            // MEASURED on a Galaxy S24 Ultra: turning the panel off leaves the
            // touchscreen live, and every accidental tap buzzed. Touch
            // vibration is paused while the screen is off and put back after.
            Task {
                await settingsGuard?.override(.system, "haptic_feedback_enabled", to: "0",
                                              phoneID: phoneID, serial: serial)
            }
        }
    }

    private func reapplyPhoneScreenState() {
        guard store.mirroring.isPhoneScreenOff, let session = store.mirroring.session else { return }
        session.input.setDisplayPower(on: false)
    }

    private func mirroringEnded(phoneID: String) {
        store.mirroring.isPhoneScreenOff = false
        restoreSettingsIfPossible(phoneID: phoneID)
    }

    /// Put back any phone setting Conduit changed, over any ready transport.
    /// A phone that is not attached is restored when it next attaches.
    private func restoreSettingsIfPossible(phoneID: String) {
        guard let settingsGuard, settingsGuard.hasPending(for: phoneID),
              let serial = PhoneRegistry.targets(for: phoneID, attached: Array(attached.values)).first?.serial
        else { return }
        Task { await settingsGuard.restoreAll(phoneID: phoneID, serial: serial) }
    }

    public func allowCompanionSettingsControl(phoneID: String) {
        guard let adb, let serial = PhoneRegistry.targets(for: phoneID, attached: Array(attached.values)).first?.serial
        else { return }
        Task {
            let granted = await Task.detached { adb.grantCompanionSettingsControl(serial: serial) }.value
            if granted {
                store.record(ActivityEvent(kind: .permissionRequired, title: "Conduit for Android can manage Wireless debugging"))
            } else {
                store.record(ActivityEvent(kind: .error, title: "Couldn't allow Wireless debugging control",
                                           detail: "Update Conduit for Android on the phone, then try again."))
            }
            refreshCompanionApp(phoneID: phoneID, serial: serial)
        }
    }

    private func refreshCompanionApp(phoneID: String, serial: String) {
        guard let adb else { return }
        Task {
            guard let status = await Task.detached(operation: { adb.companionAppStatus(serial: serial) }).value else { return }
            companionApps[phoneID] = status
            publishPhones()
        }
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
            if preferences.autoConnectWireless {
                discovery.start()
                reconnector?.start()
            } else {
                reconnector?.stop()
                discovery.stop()
            }
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
            var entry = AttachedTransport(device: device, properties: attached[device.serial]?.properties,
                                          identityHint: wifiIdentities[device.serial])
            if !device.isReady { entry.properties = nil }
            next[device.serial] = entry
        }
        attached = next
        wifiIdentities = wifiIdentities.filter { next[$0.key] != nil }
        propertyFailures = propertyFailures.filter { next[$0.key] != nil }

        for entry in next.values where entry.device.isReady && entry.properties == nil {
            loadProperties(serial: entry.device.serial)
        }

        publishPhones()
        recordConnectionChanges(from: before, to: store.phones)
        announcePendingConnections()
        mirroring?.phonesChanged()
        reconnector?.evaluate()
    }

    private func loadProperties(serial: String) {
        guard let adb, !propertiesInFlight.contains(serial) else { return }
        propertiesInFlight.insert(serial)

        Task {
            let properties = await Task.detached { adb.properties(of: serial) }.value
            propertiesInFlight.remove(serial)
            guard attached[serial] != nil else { return }

            guard let properties else {
                // MEASURED: a transport that has just appeared — above all
                // over Wi-Fi as the cable is pulled — can refuse its first
                // shell command. Without a retry it stays anonymous, and an
                // anonymous transport can never carry a session.
                let failures = (propertyFailures[serial] ?? 0) + 1
                propertyFailures[serial] = failures
                guard failures < 6 else {
                    CoreLog.devices.error("could not read a phone's properties after \(failures) attempts")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures)) { [weak self] in
                    guard let self, self.attached[serial]?.device.isReady == true,
                          self.attached[serial]?.properties == nil else { return }
                    self.loadProperties(serial: serial)
                }
                return
            }
            propertyFailures[serial] = nil
            if companionApps[properties.hardwareSerial] == nil {
                refreshCompanionApp(phoneID: properties.hardwareSerial, serial: serial)
            }
            if store.mirroring.phoneID != properties.hardwareSerial || !store.mirroring.isPhoneScreenOff {
                restoreSettingsIfPossible(phoneID: properties.hardwareSerial)
            }

            let before = store.phones
            attached[serial]?.properties = properties
            remember(properties)
            publishPhones()
            recordConnectionChanges(from: before, to: store.phones)
            announcePendingConnections()
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
                                            preferredID: store.preferences.preferredPhoneID,
                                            companionApps: companionApps)

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
                guard phone.osVersion != nil else {
                    unannouncedConnections[phone.id] = transport
                    continue
                }
                announceConnection(phone, over: transport)
            case .unauthorized:
                store.record(ActivityEvent(kind: .permissionRequired, title: "Allow debugging on \(phone.name)",
                                           detail: "Tap Allow on the phone so this Mac can connect."))
            case .disconnected where previous?.isConnected == true:
                announcedPhones.remove(phone.id)
                store.record(ActivityEvent(kind: .phoneDisconnected, title: "\(phone.name) disconnected"))
            default:
                break
            }
        }
    }

    private func announceConnection(_ phone: PhoneDevice, over transport: PhoneTransport) {
        guard announcedPhones.insert(phone.id).inserted else { return }
        store.record(ActivityEvent(kind: .phoneConnected, title: "\(phone.name) connected",
                                   detail: transport == .usb ? "Over USB" : "Over Wi-Fi"))
    }

    private func announcePendingConnections() {
        for (id, transport) in unannouncedConnections {
            // The phone's ID can change once its hardware serial is known
            // (a host:port transport), so match on either.
            guard let phone = store.phones.first(where: { $0.id == id })
                    ?? store.connectedPhones.first(where: { $0.osVersion != nil && $0.transports.contains(transport) }),
                  phone.osVersion != nil, phone.connection.isConnected
            else { continue }
            unannouncedConnections[id] = nil
            announceConnection(phone, over: transport)
        }
        // Forget phones that left before they could be announced. While any
        // phone is still loading its properties its ID may not match yet,
        // so keep waiting until none is.
        if !store.connectedPhones.contains(where: { $0.osVersion == nil }) {
            let connectedIDs = Set(store.connectedPhones.map(\.id))
            unannouncedConnections = unannouncedConnections.filter { connectedIDs.contains($0.key) }
        }
    }

    // MARK: - Wireless debugging

    private func wifiTransportConnected(_ serial: String, phoneID: String) {
        wifiIdentities[serial] = phoneID
        guard attached[serial] != nil, attached[serial]?.identityHint != phoneID else { return }
        let before = store.phones
        attached[serial]?.identityHint = phoneID
        publishPhones()
        recordConnectionChanges(from: before, to: store.phones)
        announcePendingConnections()
        mirroring?.phonesChanged()
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
