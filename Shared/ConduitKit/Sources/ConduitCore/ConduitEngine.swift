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
    private var touchGuard: PhoneTouchGuard?
    private var linkServer: LinkServer?
    private var linkTrust: LinkTrust?
    private var linkIdentity: LinkIdentity?
    /// The connection waiting for the person to compare six digits.
    private var pairingConnection: LinkConnection?
    /// Phones with a live Conduit Link connection right now.
    private var linkedNow: Set<String> = []

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
        let settingsGuard = PhoneSettingsGuard(adb: adb, defaults: defaults)
        self.settingsGuard = settingsGuard
        let touchGuard = PhoneTouchGuard(adb: adb, settings: settingsGuard)
        touchGuard.onStatus = { [weak self] status in self?.touchGuardChanged(status) }
        self.touchGuard = touchGuard

        startLink()

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
        reconnector.hotspotTargets = { [weak self] in
            self?.known.compactMapValues(\.hotspotPort) ?? [:]
        }
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
            touchGuard?.stop(serial: serial)
            store.mirroring.touchGuard = .off
            session.input.setDisplayPower(on: true)
            store.mirroring.isPhoneScreenOff = false
            store.record(ActivityEvent(kind: .mirroringStarted, title: "Phone screen turned on"))
            Task { await settingsGuard?.restoreAll(phoneID: phoneID, serial: serial) }
        } else {
            store.mirroring.isPhoneScreenOff = true
            session.input.setDisplayPower(on: false)
            store.record(ActivityEvent(kind: .mirroringStopped, title: "Phone screen turned off",
                                       detail: "Mirroring continues."))
            // MEASURED on a Galaxy S24 Ultra: turning the panel off leaves the
            // touchscreen live. The touch guard makes the phone ignore it;
            // touch vibration is paused too, for phones where the guard
            // cannot run, and put back after.
            touchGuard?.start(phoneID: phoneID, serial: serial, companionApp: companionApps[phoneID])
            Task {
                await settingsGuard?.override(.system, "haptic_feedback_enabled", to: "0",
                                              phoneID: phoneID, serial: serial)
            }
        }
    }

    private func reapplyPhoneScreenState() {
        guard store.mirroring.isPhoneScreenOff, let session = store.mirroring.session else { return }
        session.input.setDisplayPower(on: false)
        // A new server may run over another transport; keep the guard's
        // lease renewals going there.
        let guardRunning = store.mirroring.touchGuard == .active || store.mirroring.touchGuard == .starting
        if guardRunning, let phoneID = store.mirroring.phoneID, let serial = mirroring?.currentSerial {
            touchGuard?.start(phoneID: phoneID, serial: serial, companionApp: companionApps[phoneID])
        }
    }

    private func touchGuardChanged(_ status: TouchGuardStatus) {
        guard store.mirroring.isPhoneScreenOff else { return }
        let previous = store.mirroring.touchGuard
        // Re-checking a running guard after mirroring resumes is not news.
        if previous == .active && status == .starting { return }
        store.mirroring.touchGuard = status
        guard status != previous else { return }
        switch status {
        case .active:
            if previous == .starting {
                store.record(ActivityEvent(kind: .mirroringStopped, title: "Touches on the phone are ignored",
                                           detail: "Until its screen is back on. The Mac keeps control."))
            }
        case .unavailable(let reason):
            store.record(ActivityEvent(kind: .permissionRequired, title: "The phone still responds to touch",
                                       detail: reason))
        case .off, .starting:
            break
        }
    }

    private func mirroringEnded(phoneID: String) {
        touchGuard?.stop(serial: PhoneRegistry.targets(for: phoneID, attached: Array(attached.values)).first?.serial)
        store.mirroring.touchGuard = .off
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

    /// Arm adb's TCP mode so this phone can be reached over its own hotspot.
    public func prepareHotspotConnection(phoneID: String) {
        guard let adb, let serial = PhoneRegistry.targets(for: phoneID, attached: Array(attached.values)).first?.serial
        else {
            store.record(ActivityEvent(kind: .error, title: "Connect the phone first",
                                       detail: "Plug it in, or connect it over Wi-Fi, then get it ready for its hotspot."))
            return
        }
        let port = HotspotLink.defaultPort
        Task {
            let armed = await Task.detached { adb.armTCPMode(serial: serial, port: port) }.value
            guard armed else {
                store.record(ActivityEvent(kind: .error, title: "Couldn't get the phone ready for its hotspot",
                                           detail: "The phone refused to open its adb port."))
                return
            }
            known[phoneID]?.hotspotPort = port
            saveKnownPhones()
            publishPhones()
            store.record(ActivityEvent(kind: .phoneConnected, title: "Ready for this phone's hotspot",
                                       detail: "Turn the phone's hotspot on and join this Mac to it."))
        }
    }

    /// Close the phone's adb port again.
    public func stopHotspotConnection(phoneID: String) {
        known[phoneID]?.hotspotPort = nil
        saveKnownPhones()
        publishPhones()

        guard let adb, let serial = PhoneRegistry.targets(for: phoneID, attached: Array(attached.values)).first?.serial
        else { return }
        Task {
            let closed = await Task.detached { adb.restoreUSBMode(serial: serial) }.value
            store.record(closed
                ? ActivityEvent(kind: .phoneDisconnected, title: "The phone's adb port is closed again")
                : ActivityEvent(kind: .error, title: "Couldn't close the phone's adb port",
                                detail: "It closes by itself when the phone restarts."))
        }
    }

    // MARK: - Conduit Link

    /// The channel to Conduit for Android: state, links, files and calls. It
    /// needs no developer options, and works over any network the two share
    /// — including the phone's own hotspot.
    private func startLink() {
        let identity = LinkIdentity.loadOrCreate()
        let trust = LinkTrust(defaults: defaults)
        linkTrust = trust
        linkIdentity = identity

        let server = LinkServer(identity: identity, trust: trust) {
            identity.deviceInfo(name: Host.current().localizedName ?? "Mac",
                                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
        }
        server.onListening = { [weak self] port, advertising in
            guard let self else { return }
            store.link.port = port
            store.link.isAdvertising = advertising
            if port != nil { sendLinkHintToAttachedPhones() }
            if port != nil, !advertising {
                store.record(ActivityEvent(
                    kind: .permissionRequired, title: "Let Conduit use the local network",
                    detail: "macOS is blocking the advert phones look for. Allow Conduit in System Settings → Privacy & Security → Local Network."))
            }
        }
        server.onPairing = { [weak self] connection, request in
            guard let self else { return }
            pairingConnection = connection
            store.link.pairingRequest = LinkPairingRequest(code: request.code, deviceName: request.device.name)
        }
        server.onReady = { [weak self] peer in
            guard let self else { return }
            pairingConnection = nil
            store.link.pairingRequest = nil
            closeLinkPairing()
            store.record(ActivityEvent(kind: .phoneConnected, title: "\(peer.name) is linked to this Mac"))
            linkedNow.insert(peer.id)
            publishLinkedPhones()
        }
        server.onEnvelope = { [weak self] envelope, peer in
            self?.linkReceived(envelope, from: peer)
        }
        server.onClosed = { [weak self] peer, error in
            guard let self else { return }
            if let peer {
                store.record(ActivityEvent(kind: .phoneDisconnected, title: "\(peer.name) left this Mac",
                                           detail: error?.message))
            } else if let error, store.link.pairingRequest != nil {
                store.record(ActivityEvent(kind: .error, title: "Pairing didn't finish", detail: error.message))
            }
            if let peer { linkedNow.remove(peer.id) }
            pairingConnection = nil
            store.link.pairingRequest = nil
            publishLinkedPhones()
        }
        linkServer = server
        server.start()
        publishLinkedPhones()
    }

    public func openLinkPairing() {
        linkServer?.pairingOpen = true
        store.link.isPairingOpen = true
        sendLinkHintToAttachedPhones()
        store.record(ActivityEvent(kind: .permissionRequired, title: "Ready to add a phone",
                                   detail: "In Conduit for Android, choose Add Mac."))
    }

    public func closeLinkPairing() {
        linkServer?.pairingOpen = false
        store.link.isPairingOpen = false
    }

    public func confirmLinkPairing() {
        pairingConnection?.confirmPairing()
        store.link.pairingRequest = nil
    }

    public func rejectLinkPairing() {
        pairingConnection?.rejectPairing()
        pairingConnection = nil
        store.link.pairingRequest = nil
    }

    public func forgetLinkedPhone(id: String) {
        linkTrust?.forget(id: id)
        linkServer?.disconnect(peerID: id)
        linkedNow.remove(id)
        publishLinkedPhones()
        store.record(ActivityEvent(kind: .phoneDisconnected, title: "A phone was unlinked from this Mac"))
    }

    /// Answer what this build understands, and say so plainly for the rest:
    /// an unknown action gets `unsupported`, as the spec requires.
    private func linkReceived(_ envelope: Envelope, from peer: LinkPeer) {
        switch envelope.kind {
        case .command(let requestID, let action) where action == .sessionPing:
            linkServer?.send(Envelope.success(to: requestID, payload: envelope.payload), to: peer.id)
        case .command(let requestID, let action):
            linkServer?.send(Envelope.failure(to: requestID,
                                              ProtocolError(.unsupported, "This version of Conduit for Mac does not do that yet.")),
                             to: peer.id)
            CoreLog.engine.debug("Conduit Link: no handler for \(action.rawValue)")
        case .response, .event:
            break
        }
    }

    /// Tell Conduit for Android where this Mac listens, over adb. That finds
    /// the Mac where Bonjour cannot: on the phone's own hotspot, or before
    /// macOS lets Conduit advertise itself. It only says where to knock — the
    /// handshake still proves who answers.
    private func sendLinkHint(serial: String) {
        guard let adb, let port = store.link.port, let identity = linkIdentity else { return }
        let hosts = LinkAddresses.ipv4()
        guard !hosts.isEmpty else { return }
        let name = Host.current().localizedName ?? "Mac"
        Task.detached {
            adb.run(["-s", serial, "shell", "am", "broadcast", "-f", "32",
                     "-n", "com.khushi.conduit/com.khushi.conduit.link.MacHint",
                     "--es", "id", identity.deviceID, "--es", "name", ADBParsing.shellQuoted(name),
                     "--es", "hosts", hosts.joined(separator: ","), "--ei", "port", String(port)], timeout: 8)
        }
    }

    private func sendLinkHintToAttachedPhones() {
        for transport in attached.values where transport.device.isReady {
            guard let phoneID = transport.properties?.hardwareSerial ?? transport.identityHint,
                  case .installed = companionApps[phoneID] ?? .unknown
            else { continue }
            sendLinkHint(serial: transport.device.serial)
        }
    }

    private func publishLinkedPhones() {
        let peers = linkTrust.map { Array($0.peers.values) } ?? []
        store.link.phones = peers
            .map { LinkedPhone(id: $0.id, name: $0.name, isConnected: linkedNow.contains($0.id), lastSeen: $0.lastSeen) }
            .sorted { $0.lastSeen > $1.lastSeen }
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

    /// Keep the hotspot state honest: the port may have been opened or
    /// closed outside Conduit, and the phone closes it when it restarts.
    private func refreshHotspotPort(phoneID: String, serial: String) {
        guard let adb else { return }
        Task {
            let port = await Task.detached { adb.tcpPort(serial: serial) }.value
            guard known[phoneID] != nil, known[phoneID]?.hotspotPort != port else { return }
            known[phoneID]?.hotspotPort = port
            saveKnownPhones()
            publishPhones()
        }
    }

    private func refreshCompanionApp(phoneID: String, serial: String) {
        guard let adb else { return }
        Task {
            guard let status = await Task.detached(operation: { adb.companionAppStatus(serial: serial) }).value else { return }
            companionApps[phoneID] = status
            publishPhones()
            if case .installed = status { sendLinkHint(serial: serial) }
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
            refreshHotspotPort(phoneID: properties.hardwareSerial, serial: serial)
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
        var phone = known[properties.hardwareSerial]
            ?? KnownPhone(id: properties.hardwareSerial, name: properties.name, lastSeen: Date())
        phone.name = properties.name
        phone.model = properties.model
        phone.manufacturer = properties.manufacturer
        phone.osVersion = properties.osVersion
        phone.lastSeen = Date()
        known[properties.hardwareSerial] = phone
        saveKnownPhones()
    }

    private func saveKnownPhones() {
        if let data = try? JSONEncoder().encode(Array(known.values)) {
            defaults.set(data, forKey: Key.knownPhones)
        }
    }

    private func publishPhones() {
        store.phones = PhoneRegistry.phones(attached: Array(attached.values), known: known,
                                            preferredID: store.preferences.preferredPhoneID,
                                            companionApps: companionApps,
                                            gateway: HotspotLink.currentGateway())

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
