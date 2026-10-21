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
import CryptoKit
import Foundation
import Network

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
    private let hotspotRequester = HotspotRequester()
    private var networkMonitor: NWPathMonitor?
    private var offlineSince: Date?
    private var lastAutomaticHotspotAsk = Date.distantPast
    /// Automatic asks in the current offline spell: the first, and one retry.
    private var automaticAsks = 0
    /// Links sent to a phone, waiting for its answer, by request ID.
    private var sentLinks: [String: (phone: String, site: String)] = [:]
    /// Counts link sends, so an old outcome is not cleared by a newer one.
    private var linkSendGeneration = 0
    private let ringer = MacRinger()
    private let trackpad = TrackpadInput()
    /// When the phone last moved the pointer, to show that it is in control.
    private var lastPhoneInput = Date.distantPast
    private var trackpadIdleCheck: DispatchWorkItem?
    private var lastTrustCheck = Date.distantPast
    /// Repeats this Mac's address to attached phones while none is linked.
    private var hintTimer: Timer?
    /// The request ID of the notification list this Mac asked the phone for.
    private var notificationSyncID: String?

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
    private var lastClipboardToPhoneActivity = Date.distantPast
    private let macClipboard = MacClipboardWatcher()
    private var phoneClipboard: PhoneClipboardSession?
    private var phoneFiles: PhoneFiles?
    /// A digest of the last text that crossed, either way — so text that
    /// just arrived is not sent straight back. Never the text itself.
    private var lastClipboardDigest: Data?
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
        refreshTrackpadPermission()
        macClipboard.onCopy = { [weak self] text in self?.macCopied(text) }
        macClipboard.start()
        refreshClipboardStatus()

        guard let adb else {
            store.tools.adb = .missing
            store.record(ActivityEvent(kind: .error, title: "adb isn't installed",
                                       detail: "Install it with: brew install android-platform-tools"))
            return
        }
        store.tools.adb = .available(path: adb.path)

        phoneFiles = PhoneFiles(adb: adb, state: store.files)

        let phoneClipboard = PhoneClipboardSession(adb: adb)
        phoneClipboard.onClipboard = { [weak self] text in self?.deviceClipboardChanged(text) }
        phoneClipboard.onConnectionChange = { [weak self] in self?.refreshClipboardStatus() }
        self.phoneClipboard = phoneClipboard

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
        // The mirroring session carries the clipboard itself.
        phoneClipboard?.run(on: nil)
        mirroring.start(phoneID: id)
    }

    public func stopMirroring() {
        mirroring?.stop()
    }

    public func restartMirroring() {
        mirroring?.restart()
    }

    public func sendMacClipboardToPhone() {
        // The person's own click: macOS may ask, and that is expected.
        guard let text = MacClipboardWatcher.readText(asking: true) else {
            store.record(ActivityEvent(kind: .error, title: "Nothing to send",
                                       detail: "The clipboard is empty, or a password manager marked it private."))
            return
        }
        refreshClipboardStatus()
        if sendClipboardToPhone(text) {
            store.record(ActivityEvent(kind: .clipboardSynced, title: "Clipboard sent to phone"))
        } else {
            store.record(ActivityEvent(kind: .error, title: "No way to reach the phone",
                                       detail: "Link the phone, or connect it over USB or Wi-Fi."))
        }
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
        defer { updatePhoneClipboard() }
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
            syncNotifications(with: peer)
            refreshClipboardStatus()
        }
        server.onEnvelope = { [weak self] envelope, peer in
            self?.linkReceived(envelope, from: peer)
        }
        server.onInput = { [weak self] event, peer in
            self?.phoneInput(event, from: peer)
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
            // The phone's notifications belong to the phone: when it goes,
            // what this Mac is showing goes with it.
            store.removeAllNotifications()
            store.link.notificationsReady = false
            refreshClipboardStatus()
            // A phone that vanishes mid-drag must not leave a button held.
            trackpad.releaseEverything()
            store.link.trackpadActive = false
            pairingConnection = nil
            store.link.pairingRequest = nil
            publishLinkedPhones()
        }
        linkServer = server
        server.start()
        publishLinkedPhones()

        // A phone that restarted or updated may have lost where this Mac
        // is; while none is linked, say it again now and then over adb.
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.linkedNow.isEmpty else { return }
                self.sendLinkHintToAttachedPhones()
            }
        }
        watchForGoingOffline()
    }

    // MARK: - Hotspot on request

    public func requestPhoneHotspot() {
        askForHotspot(automatically: false)
    }

    /// Ask every linked phone over Bluetooth to turn its hotspot on. Android
    /// does not let an app do that itself, so the phone shows a notification
    /// that opens the switch; this Mac then rejoins the hotspot it remembers.
    private func askForHotspot(automatically: Bool) {
        guard let identity = linkIdentity, let trust = linkTrust, !hotspotRequester.isAsking else { return }
        let phones = trust.peers.values.filter { $0.platform == .android }
        guard !phones.isEmpty else {
            if !automatically {
                store.record(ActivityEvent(kind: .error, title: "Link a phone first",
                                           detail: "Conduit asks a linked phone for its hotspot."))
            }
            return
        }
        let requests = phones.compactMap { try? HotspotRequest.make(identity: identity, phoneID: $0.id) }
        store.link.hotspotRequest = .asking

        hotspotRequester.ask(requests) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .asked:
                store.link.hotspotRequest = .asked(Date())
                store.record(ActivityEvent(kind: .phoneConnected, title: "Asked your phone for its hotspot",
                                           detail: "Tap the notification on the phone to turn it on."))
            case .noPhoneNearby:
                store.link.hotspotRequest = .noPhoneNearby
                // Asking the moment the network goes can beat the phone to
                // it; give it one more chance while this Mac is still offline.
                if automatically, automaticAsks < 2 {
                    automaticAsks += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                        guard let self, offlineSince != nil else { return }
                        askForHotspot(automatically: true)
                    }
                }
                if !automatically {
                    store.record(ActivityEvent(kind: .error, title: "No linked phone is nearby",
                                               detail: "Keep the phone close, with Bluetooth on and Conduit for Android set up."))
                }
            case .bluetoothOff:
                store.link.hotspotRequest = .bluetoothOff
                if !automatically { store.record(ActivityEvent(kind: .error, title: "Turn on Bluetooth to ask your phone")) }
            case .bluetoothDenied:
                store.link.hotspotRequest = .bluetoothDenied
                store.record(ActivityEvent(
                    kind: .permissionRequired, title: "Let Conduit use Bluetooth",
                    detail: "Allow Conduit in System Settings → Privacy & Security → Bluetooth."))
            case .failed(let message):
                store.link.hotspotRequest = .failed(message)
                if !automatically { store.record(ActivityEvent(kind: .error, title: "Couldn't ask your phone", detail: message)) }
            }
        }
    }

    /// When this Mac loses its network, ask a linked phone for its hotspot —
    /// the way an iPhone offers its hotspot to its Mac. A network change looks
    /// offline for a moment, so it waits five seconds, and asks at most once
    /// every ten minutes so the phone is not pestered.
    private func watchForGoingOffline() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(online: online) }
        }
        monitor.start(queue: .main)
        networkMonitor = monitor
    }

    private func networkChanged(online: Bool) {
        guard !online else {
            offlineSince = nil
            automaticAsks = 0
            return
        }
        guard offlineSince == nil else { return }
        let since = Date()
        offlineSince = since
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, offlineSince == since, store.preferences.askPhoneForHotspot,
                  Date().timeIntervalSince(lastAutomaticHotspotAsk) > 600
            else { return }
            lastAutomaticHotspotAsk = Date()
            automaticAsks = 1
            askForHotspot(automatically: true)
        }
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
        case .command(let requestID, let action) where action == .linkSend:
            openLink(envelope, requestID: requestID, from: peer)
        case .command(let requestID, let action) where action == .clipboardSet:
            clipboardFromPhone(envelope, requestID: requestID, from: peer)
        case .command(let requestID, let action) where action == .trackpadStart:
            linkServer?.send(trackpadAnswer(to: requestID), to: peer.id)
        case .command(let requestID, let action) where action == .trackpadStop:
            trackpad.releaseEverything()
            store.link.trackpadActive = false
            linkServer?.send(Envelope.success(to: requestID), to: peer.id)
        case .command(let requestID, let action) where action == .macFind:
            ring(for: peer)
            linkServer?.send(Envelope.success(to: requestID), to: peer.id)
        case .response(let requestID, let outcome):
            linkAnswered(requestID: requestID, outcome: outcome, payload: envelope.payload)
        case .command(let requestID, let action):
            linkServer?.send(Envelope.failure(to: requestID,
                                              ProtocolError(.unsupported, "This version of Conduit for Mac does not do that yet.")),
                             to: peer.id)
            CoreLog.engine.debug("Conduit Link: no handler for \(action.rawValue)")
        case .event(let name, _, _, _):
            phoneEvent(name, payload: envelope.payload, from: peer)
        }
    }

    // MARK: - Notifications

    private func phoneEvent(_ name: EventName, payload: [String: JSONValue]?, from peer: LinkPeer) {
        switch name {
        case .notificationPosted:
            guard let payload, let notification = try? JSONValue.object(payload).decoded(as: PhoneNotification.self) else {
                CoreLog.engine.debug("Conduit Link: a notification arrived that could not be read")
                return
            }
            // What happened, never what it said.
            CoreLog.engine.notice("the phone sent a notification")
            // A phone sending notifications has plainly been allowed to,
            // whatever it said before.
            store.link.notificationsReady = true
            store.link.notificationsRefusal = nil
            store.show(notification)
        case .notificationRemoved:
            guard let key = payload?["key"]?.stringValue else { return }
            CoreLog.engine.notice("the phone took a notification back")
            store.removeNotification(key: key)
        default:
            CoreLog.engine.debug("Conduit Link: no handler for event \(name.rawValue)")
        }
    }

    /// Ask the phone what it is already showing, when a link comes up.
    private func syncNotifications(with peer: LinkPeer) {
        let command = Envelope.command(.notificationSync)
        guard case .command(let requestID, _) = command.kind else { return }
        notificationSyncID = requestID
        linkServer?.send(command, to: peer.id)
    }

    private func notificationsSynced(_ outcome: Envelope.Outcome, payload: [String: JSONValue]?) {
        switch outcome {
        case .success:
            store.link.notificationsReady = true
            store.link.notificationsRefusal = nil
            guard case .array(let list)? = payload?["notifications"] else { return }
            CoreLog.engine.notice("the phone is sending notifications; \(list.count) showing")
            for value in list {
                guard let notification = try? value.decoded(as: PhoneNotification.self) else { continue }
                store.show(notification)
            }
        case .failure(let error):
            // The phone says why — usually that Android has not let Conduit
            // see notifications yet.
            CoreLog.engine.notice("the phone is not sending notifications: \(error.code.rawValue)")
            store.link.notificationsReady = false
            store.link.notificationsRefusal = error.message
        }
    }

    public func refreshNotifications() {
        guard let peer = linkTrust?.peers.values.first(where: { linkedNow.contains($0.id) }) else {
            store.link.notificationsReady = false
            store.link.notificationsRefusal = "No phone is linked right now."
            return
        }
        syncNotifications(with: peer)
    }

    public func dismissNotification(key: String) {
        CoreLog.engine.notice("asked the phone to dismiss a notification")
        sendNotificationCommand(.notificationDismiss, key: key)
        // The phone confirms with notification.removed; taking it off the
        // list now keeps the Mac from feeling slow.
        store.removeNotification(key: key)
    }

    public func openNotification(key: String) {
        CoreLog.engine.notice("asked the phone to open a notification")
        sendNotificationCommand(.notificationOpen, key: key)
    }

    public func clearNotifications() {
        store.removeAllNotifications()
    }

    private func sendNotificationCommand(_ action: ActionName, key: String) {
        guard let peer = linkTrust?.peers.values.first(where: { linkedNow.contains($0.id) }) else { return }
        linkServer?.send(Envelope.command(action, payload: ["key": .string(key)]), to: peer.id)
    }

    // MARK: - The phone as a trackpad

    /// Input from the phone's trackpad screen. It moves this Mac's pointer
    /// only while the person allows it and macOS trusts Conduit.
    private func phoneInput(_ event: InputEvent, from peer: LinkPeer) {
        guard store.preferences.phoneTrackpad else { return }

        // Asking macOS whether Conduit is trusted talks to the system, and
        // pointer moves arrive in streams — so it is asked once a second.
        let now = Date()
        if now.timeIntervalSince(lastTrustCheck) > 1 {
            lastTrustCheck = now
            refreshTrackpadPermission()
        }
        guard store.link.trackpadTrusted else { return }

        trackpad.sensitivity = store.preferences.trackpadSensitivity
        trackpad.naturalScrolling = store.preferences.naturalScrolling
        trackpad.handle(event)
        showTrackpadInUse()

        // A short buzz on the phone as a click lands, the way a Mac trackpad
        // answers a press.
        if case .button(_, true) = event, store.preferences.trackpadHaptics {
            linkServer?.send(Vibration(durationMs: 12, amplitude: 140).frame, to: peer.id)
        }
    }

    /// The phone opened its trackpad screen. It is told plainly whether this
    /// Mac will take it: a phone swiping at a Mac that is dropping every
    /// event has no other way to know.
    private func trackpadAnswer(to requestID: String) -> Envelope {
        guard store.preferences.phoneTrackpad else {
            return Envelope.failure(to: requestID, ProtocolError(.permissionDenied,
                "This Mac is set not to be controlled from the phone. Turn it on in Conduit → Trackpad."))
        }
        refreshTrackpadPermission()
        guard store.link.trackpadTrusted else {
            CoreLog.engine.notice("the phone's trackpad opened, but macOS has not allowed Conduit to move the pointer")
            // Put the macOS question in front of the person now, while they
            // are reaching for the trackpad, rather than leaving them to
            // find the setting. macOS shows it once; after that the Trackpad
            // page and System Settings carry on.
            TrackpadInput.requestTrust()
            store.record(ActivityEvent(kind: .permissionRequired, title: "The phone's trackpad needs permission",
                                       detail: "Allow Conduit under Privacy & Security → Accessibility"))
            return Envelope.failure(to: requestID, ProtocolError(.permissionDenied,
                "Conduit is not allowed to move this Mac's pointer. On the Mac, open Conduit → Trackpad and allow it under Accessibility."))
        }
        CoreLog.engine.notice("the phone's trackpad is open")
        return Envelope.success(to: requestID)
    }

    /// Says the phone is in control, and stops saying so once it goes quiet.
    /// Rescheduled at most twice a second: pointer moves arrive in streams.
    private func showTrackpadInUse() {
        let now = Date()
        if !store.link.trackpadActive { store.link.trackpadActive = true }
        guard now.timeIntervalSince(lastPhoneInput) > 0.5 else { return }
        lastPhoneInput = now

        trackpadIdleCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            guard let self, Date().timeIntervalSince(lastPhoneInput) >= 1.5 else { return }
            store.link.trackpadActive = false
        }
        trackpadIdleCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: check)
    }

    public func requestTrackpadPermission() {
        TrackpadInput.requestTrust()
        refreshTrackpadPermission()
    }

    public func refreshTrackpadPermission() {
        let trusted = TrackpadInput.isTrusted
        if trusted != store.link.trackpadTrusted { store.link.trackpadTrusted = trusted }
    }

    // MARK: - Find my Mac

    /// The phone is looking for this Mac: ring until someone here stops it,
    /// or until the ringer's own deadline.
    private func ring(for peer: LinkPeer) {
        CoreLog.engine.notice("a linked phone is looking for this Mac")
        store.link.ringing = RingingMac(phoneName: peer.name, since: Date())
        store.record(ActivityEvent(kind: .ringing, title: "\(peer.name) is looking for this Mac",
                                   detail: "Ringing until you stop it"))
        ringer.start { [weak self] in
            guard let self else { return }
            store.link.ringing = nil
        }
    }

    public func stopRinging() {
        guard ringer.isRinging || store.link.ringing != nil else { return }
        ringer.stop()
        store.link.ringing = nil
        CoreLog.engine.notice("stopped ringing")
    }

    // MARK: - Links

    /// A linked phone shared a link: open it in the default browser, if it is
    /// a web link and this Mac opens links from phones.
    private func openLink(_ envelope: Envelope, requestID: String, from peer: LinkPeer) {
        guard store.preferences.openLinksFromPhone else {
            CoreLog.engine.notice("turned down a link from a phone: opening links is off")
            linkServer?.send(Envelope.failure(to: requestID, ProtocolError(
                .permissionDenied, "This Mac is set not to open links from phones.")), to: peer.id)
            return
        }
        guard let text = envelope.payload?["url"]?.stringValue, let url = LinkSharing.acceptableURL(text) else {
            CoreLog.engine.notice("turned down a link from a phone: not a web link")
            linkServer?.send(Envelope.failure(to: requestID, ProtocolError(
                .invalidRequest, "Only web links can be opened.")), to: peer.id)
            return
        }
        NSWorkspace.shared.open(url)
        CoreLog.engine.notice("opened a link from a linked phone")
        linkServer?.send(Envelope.success(to: requestID), to: peer.id)
        store.record(ActivityEvent(kind: .linkReceived, title: "Opened a link from \(peer.name)",
                                   detail: LinkSharing.siteName(of: url)))
    }

    public func sendLinkToPhone() {
        guard let text = NSPasteboard.general.string(forType: .string), let url = LinkSharing.acceptableURL(text) else {
            finishLinkSend(.noLinkOnClipboard)
            return
        }
        guard let peer = linkTrust?.peers.values.first(where: { linkedNow.contains($0.id) }) else {
            finishLinkSend(.noPhoneConnected)
            return
        }

        let site = LinkSharing.siteName(of: url)
        let command = Envelope.command(.linkSend, payload: ["url": .string(url.absoluteString)])
        guard case .command(let requestID, _) = command.kind else { return }
        sentLinks[requestID] = (peer.name, site)
        linkSendGeneration += 1
        store.link.linkSend = .sending(site: site)
        linkServer?.send(command, to: peer.id)
        CoreLog.engine.notice("sent a link to a linked phone")

        // The spec gives a command 15 seconds to be answered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let sent = sentLinks.removeValue(forKey: requestID) else { return }
            store.record(ActivityEvent(kind: .error, title: "\(sent.phone) didn't answer", detail: sent.site))
            finishLinkSend(.failed("\(sent.phone) didn't answer."))
        }
    }

    private func linkAnswered(requestID: String, outcome: Envelope.Outcome, payload: [String: JSONValue]?) {
        if requestID == notificationSyncID {
            notificationSyncID = nil
            notificationsSynced(outcome, payload: payload)
            return
        }
        guard let sent = sentLinks.removeValue(forKey: requestID) else { return }
        switch outcome {
        case .success:
            CoreLog.engine.notice("the phone took the link")
            store.record(ActivityEvent(kind: .linkReceived, title: "Sent a link to \(sent.phone)", detail: sent.site))
            finishLinkSend(.sent(site: sent.site, phone: sent.phone))
        case .failure(let error):
            CoreLog.engine.notice("the phone turned down the link: \(error.code.rawValue)")
            store.record(ActivityEvent(kind: .error, title: "\(sent.phone) didn't take the link", detail: error.message))
            finishLinkSend(.failed(error.message))
        }
    }

    /// Shows how a send ended, then goes back to idle unless another send
    /// has started since.
    private func finishLinkSend(_ status: LinkSendStatus) {
        linkSendGeneration += 1
        let generation = linkSendGeneration
        store.link.linkSend = status
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, linkSendGeneration == generation else { return }
            store.link.linkSend = .idle
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

        if !preferences.phoneTrackpad {
            trackpad.releaseEverything()
            store.link.trackpadActive = false
        }
        updatePhoneClipboard()

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
                // The engine lives as long as the app; the task holding it
                // already keeps it, so the retry can too.
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures)) {
                    guard self.attached[serial]?.device.isReady == true,
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
        defer {
            updatePhoneClipboard()
            phoneFiles?.use(serial: store.activePhoneID.flatMap {
                PhoneRegistry.targets(for: $0, attached: Array(attached.values)).first?.serial
            })
        }
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

    // MARK: - Files

    public func openPhoneFolder(_ path: String) { phoneFiles?.open(path) }
    public func refreshPhoneFolder() { phoneFiles?.refresh() }
    public func downloadPhoneFiles(_ files: [PhoneFile], to folder: URL) { phoneFiles?.download(files, to: folder) }
    public func uploadToPhone(_ urls: [URL]) { phoneFiles?.upload(urls) }
    public func deletePhoneFiles(_ files: [PhoneFile]) { phoneFiles?.delete(files) }
    public func createPhoneFolder(named name: String) { phoneFiles?.createFolder(named: name) }
    public func openPhoneFile(_ file: PhoneFile) { phoneFiles?.openCopy(file) }
    public func editPhoneFile(_ file: PhoneFile) { phoneFiles?.edit(file) }
    public func stopEditing(id: UUID) { phoneFiles?.stopEditing(id) }
    public func cancelTransfer(id: UUID) { phoneFiles?.cancel(id) }
    public func clearFinishedTransfers() { phoneFiles?.clearFinished() }

    // MARK: - Clipboard

    /// Something was copied on this Mac, and macOS lets Conduit read it.
    private func macCopied(_ text: String) {
        guard store.preferences.clipboardSync else { return }
        let digest = Self.digest(text)
        guard digest != lastClipboardDigest else { return }
        guard sendClipboardToPhone(text) else { return }
        // One activity entry per burst of copies, and never the text itself.
        if Date().timeIntervalSince(lastClipboardToPhoneActivity) > 10 {
            lastClipboardToPhoneActivity = Date()
            store.record(ActivityEvent(kind: .clipboardSynced, title: "Clipboard synced to phone"))
        }
    }

    /// Over Conduit Link when the phone is linked; over adb when a session
    /// can carry it. False when nothing reaches the phone.
    @discardableResult
    private func sendClipboardToPhone(_ text: String) -> Bool {
        lastClipboardDigest = Self.digest(text)
        if let peer = linkTrust?.peers.values.first(where: { linkedNow.contains($0.id) }) {
            linkServer?.send(Envelope.command(.clipboardSet, payload: ["text": .string(text), "sensitive": .bool(false)]),
                             to: peer.id)
            CoreLog.engine.notice("sent this Mac's clipboard to the phone over Conduit Link")
            return true
        }
        if phoneClipboard?.setPhoneClipboard(text) == true {
            CoreLog.engine.notice("sent this Mac's clipboard to the phone over adb")
            return true
        }
        if let session = store.mirroring.session, session.control.state == .connected {
            session.input.sendClipboard(text, paste: false)
            return true
        }
        return false
    }

    /// The phone sent its clipboard over Conduit Link — the person asked it
    /// to, since Android lets no app read the clipboard by itself.
    private func clipboardFromPhone(_ envelope: Envelope, requestID: String, from peer: LinkPeer) {
        guard store.preferences.clipboardSync else {
            linkServer?.send(Envelope.failure(to: requestID, ProtocolError(
                .permissionDenied, "This Mac is set not to sync the clipboard.")), to: peer.id)
            return
        }
        guard let text = envelope.payload?["text"]?.stringValue, !text.isEmpty,
              text.utf8.count <= MacClipboardWatcher.maximumBytes else {
            linkServer?.send(Envelope.failure(to: requestID, ProtocolError(
                .invalidRequest, "That clipboard was empty or too large.")), to: peer.id)
            return
        }
        lastClipboardDigest = nil
        deviceClipboardChanged(text)
        // A phone marking it sensitive (copied from a password manager)
        // gets the same courtesy here: clipboard managers skip concealed text.
        if case .bool(true)? = envelope.payload?["sensitive"] {
            NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            macClipboard.noteOwnWrite()
        }
        CoreLog.engine.notice("put the phone's clipboard on this Mac")
        linkServer?.send(Envelope.success(to: requestID), to: peer.id)
    }

    /// The background clipboard session runs while adb reaches the active
    /// phone and nothing is mirroring.
    private func updatePhoneClipboard() {
        guard let phoneClipboard else { return }
        let wanted = store.preferences.clipboardSync && !store.mirroring.status.isActive
        let serial = wanted
            ? store.activePhoneID.flatMap { PhoneRegistry.targets(for: $0, attached: Array(attached.values)).first?.serial }
            : nil
        phoneClipboard.run(on: serial)
        refreshClipboardStatus()
    }

    public func requestMacClipboardAccess() {
        // One read at the person's request: macOS shows its question and,
        // from then on, lists Conduit where Always Allow can be chosen.
        _ = MacClipboardWatcher.readText(asking: true)
        refreshClipboardStatus()
    }

    public func refreshClipboardStatus() {
        let access = MacClipboardWatcher.access
        if store.clipboard.macAccess != access { store.clipboard.macAccess = access }
        let mirroringClipboard = store.mirroring.session?.control.state == .connected
        let automatic = phoneClipboard?.isConnected == true || mirroringClipboard
        if store.clipboard.phoneToMacAutomatic != automatic { store.clipboard.phoneToMacAutomatic = automatic }
        let reachable = automatic || !linkedNow.isEmpty
        if store.clipboard.canReachPhone != reachable { store.clipboard.canReachPhone = reachable }
    }

    private static func digest(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    private func deviceClipboardChanged(_ text: String) {
        guard store.preferences.clipboardSync, !text.isEmpty else { return }
        // Text this Mac just sent comes straight back from the phone's own
        // clipboard listener; it is already here.
        let digest = Self.digest(text)
        guard digest != lastClipboardDigest else { return }
        lastClipboardDigest = digest

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        macClipboard.noteOwnWrite()

        // One activity entry per burst of copies, and never the text itself.
        if Date().timeIntervalSince(lastClipboardActivity) > 10 {
            lastClipboardActivity = Date()
            store.record(ActivityEvent(kind: .clipboardSynced, title: "Clipboard synced from phone"))
        }
    }
}
