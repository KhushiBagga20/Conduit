//
//  WirelessReconnector.swift
//  ConduitCore
//
//  Keeps every known phone attached over Wireless debugging — including
//  while it is also plugged in, so pulling the cable never leaves mirroring
//  with nothing to fall back to.
//
//  MEASURED: connecting only when the Bonjour advert changes is not enough.
//  A Wi-Fi transport can drop (adb server restart, Wi-Fi blip, the phone
//  dozing) while the phone keeps advertising the same service, and nothing
//  tried again: unplugging USB then ended mirroring. The reconnector
//  re-evaluates whenever devices or adverts change, and on a timer, with
//  backoff per phone so a phone that refuses is not hammered.
//

import ConduitMedia
import Darwin
import ConduitState
import Foundation

final class WirelessReconnector {

    // Wiring, supplied by the engine.
    var isEnabled: () -> Bool = { false }
    var isKnownPhone: (String) -> Bool = { _ in false }
    /// Wi-Fi transports currently attached for a phone, ready or not.
    var wifiTransports: (String) -> [ADBParsing.Device] = { _ in [] }
    var isMirroring: () -> Bool = { false }
    /// Phones that armed adb's TCP mode, and the port each listens on, so
    /// they can be reached over their own hotspot.
    var hotspotTargets: () -> [String: UInt16] = { [:] }
    /// Where each known phone was last found on Wi-Fi — Wireless debugging's
    /// port, and adb's TCP port when armed — for networks where Bonjour
    /// finds nothing.
    var rememberedTargets: () -> [(phoneID: String, target: String)] = { [] }
    var record: (ActivityEvent) -> Void = { _ in }
    /// Called when `adb connect` succeeds, with the new transport's serial and
    /// the phone it belongs to — known before its properties load.
    var onConnected: (_ serial: String, _ phoneID: String) -> Void = { _, _ in }

    private let adb: ADB
    private let discovery: WirelessDiscovery

    private var failures: [String: Int] = [:]
    private var nextAttempt: [String: Date] = [:]
    /// The address each phone's last failed attempt used.
    private var failedTarget: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var restartedADBServer = false
    private var timer: Timer?

    init(adb: ADB, discovery: WirelessDiscovery) {
        self.adb = adb
        self.discovery = discovery
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether this process can open a TCP connection to `host:port` within
    /// two seconds — the phone answering at all, whatever adb thinks.
    nonisolated static func canReach(_ target: String) -> Bool {
        guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) else { return false }
        let host = String(target[..<colon])
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, 2000) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }

    /// Seconds to wait after a phone's `failures`-th consecutive failure.
    nonisolated static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(2 * pow(2, Double(failures - 1)), 60)
    }

    /// Whether the last attempt to reach this phone over Wi-Fi failed.
    func hasFailed(_ phoneID: String) -> Bool {
        (failures[phoneID] ?? 0) > 0
    }

    /// Connect any known, advertising phone that has no ready Wi-Fi transport.
    func evaluate() {
        guard isEnabled() else { return }
        let now = Date()
        var advertised: Set<String> = []

        for endpoint in discovery.endpoints {
            // Only phones this Mac already knows: someone else's phone
            // advertising on the same network is not ours to connect to.
            guard let phoneID = endpoint.hardwareSerial, isKnownPhone(phoneID) else { continue }
            advertised.insert(phoneID)

            let transports = wifiTransports(phoneID)
            if transports.contains(where: \.isReady) {
                failures[phoneID] = nil
                nextAttempt[phoneID] = nil
                failedTarget[phoneID] = nil
                continue
            }
            guard !inFlight.contains(phoneID) else { continue }

            // Backoff applies to retrying the same address. MEASURED on a
            // Galaxy S24 Ultra: unplugging USB restarts Wireless debugging on
            // a new port a few seconds later, so the first attempt fails on
            // the old port — and the new one deserves an attempt at once.
            let target = "\(endpoint.host):\(endpoint.port)"
            let retryingSameAddress = failedTarget[phoneID] == target
            guard !retryingSameAddress || (nextAttempt[phoneID] ?? .distantPast) <= now else { continue }

            let discovered = endpoint
            connect(phoneID: phoneID, target: target, stale: transports.map(\.serial)) { [weak self] in
                // The port changes whenever Wireless debugging restarts; the
                // cached address may simply be old.
                self?.discovery.refresh(serviceName: discovered.serviceName)
            }
        }

        evaluateRemembered(now: now, skipping: advertised)
        evaluateHotspot(now: now)
    }

    /// MEASURED: some networks carry no Bonjour between devices that can
    /// still reach each other. A phone not advertising is tried where it was
    /// last seen — and its identity checked, since an address can be reused.
    ///
    /// Each address is tried in turn, with the phone's backoff between
    /// attempts. MEASURED: alternating two addresses slipped past a backoff
    /// kept per address, and a phone on a network that keeps devices apart
    /// was tried every five seconds. A network change starts over at once.
    private func evaluateRemembered(now: Date, skipping advertised: Set<String>) {
        let byPhone = Dictionary(grouping: rememberedTargets(), by: \.phoneID)
        for (phoneID, entries) in byPhone where !advertised.contains(phoneID) && isKnownPhone(phoneID) {
            let transports = wifiTransports(phoneID)
            guard !transports.contains(where: \.isReady), !inFlight.contains(phoneID),
                  (nextAttempt[phoneID] ?? .distantPast) <= now
            else { continue }
            let targets = entries.map(\.target)
            let target = targets.first { $0 != failedTarget[phoneID] } ?? targets[0]
            connect(phoneID: phoneID, target: target, stale: transports.map(\.serial), verifyIdentity: true)
        }
    }

    /// This Mac joined another network: what failed before may work now.
    func networkChanged() {
        failures.removeAll()
        nextAttempt.removeAll()
        failedTarget.removeAll()
        evaluate()
    }

    /// Over a hotspot there is no advert to find: Android turns Wireless
    /// debugging off with Wi-Fi, and the phone is the network. Knock on the
    /// gateway, which is the phone itself.
    private func evaluateHotspot(now: Date) {
        let armed = hotspotTargets()
        guard !armed.isEmpty, let gateway = HotspotLink.currentGateway() else { return }

        for (phoneID, port) in armed where isKnownPhone(phoneID) {
            let transports = wifiTransports(phoneID)
            guard !transports.contains(where: \.isReady), !inFlight.contains(phoneID) else { continue }

            let target = "\(gateway):\(port)"
            let retryingSameAddress = failedTarget[phoneID] == target
            guard !retryingSameAddress || (nextAttempt[phoneID] ?? .distantPast) <= now else { continue }

            connect(phoneID: phoneID, target: target, stale: transports.map(\.serial), verifyIdentity: true)
        }
    }

    private func connect(phoneID: String, target: String, stale: [String],
                         verifyIdentity: Bool = false, refresh: (() -> Void)? = nil) {
        inFlight.insert(phoneID)
        let adb = self.adb
        CoreLog.engine.notice("connecting to a known phone at a wireless address (attempt \((failures[phoneID] ?? 0) + 1))")

        Task {
            var output = await Task.detached { () -> ADB.Output in
                // A transport stuck offline shadows a fresh connection.
                for serial in stale { adb.disconnect(serial) }
                return adb.run(["connect", target], timeout: 12)
            }.value

            // MEASURED: an adb server started before the Mac changed networks
            // (or by an app without Local Network access) answers "No route
            // to host" although Conduit itself can reach the phone's port.
            // Restarting the server from Conduit clears it — once per launch,
            // never while mirroring, which it would cut, and only once Conduit
            // has reached the port itself. MEASURED as well: on a network
            // that keeps devices apart the answer is true, and a restart only
            // cut the cable connection and sent the phone back to asking
            // whether to allow this Mac.
            if !ADBParsing.connectSucceeded(output.combined), ADBParsing.isNoRouteToHost(output.combined),
               !restartedADBServer, !isMirroring(),
               await Task.detached(operation: { Self.canReach(target) }).value {
                restartedADBServer = true
                CoreLog.engine.notice("adb cannot reach a phone Conduit can reach; restarting the adb server")
                record(ActivityEvent(kind: .reconnecting, title: "Restarting adb to reach your phone over Wi-Fi"))
                output = await Task.detached { () -> ADB.Output in
                    adb.run(["kill-server"], timeout: 10)
                    adb.startServer()
                    return adb.run(["connect", target], timeout: 12)
                }.value
            }

            // Anyone's gateway can answer on an adb port. Make sure it is
            // the phone we meant before handing it to the rest of Conduit.
            var connected = ADBParsing.connectSucceeded(output.combined)
            if connected, verifyIdentity {
                let answered = await Task.detached { adb.hardwareSerial(of: target) }.value
                if answered != phoneID {
                    CoreLog.engine.notice("another device answered at the gateway; leaving it alone")
                    await Task.detached { adb.disconnect(target) }.value
                    connected = false
                }
            }

            inFlight.remove(phoneID)
            if connected {
                CoreLog.engine.notice("connected to a known phone wirelessly")
                failures[phoneID] = nil
                nextAttempt[phoneID] = nil
                failedTarget[phoneID] = nil
                onConnected(target, phoneID)
            } else {
                let count = (failures[phoneID] ?? 0) + 1
                failures[phoneID] = count
                failedTarget[phoneID] = target
                nextAttempt[phoneID] = Date().addingTimeInterval(Self.backoff(afterFailures: count))
                CoreLog.engine.error("wireless connect failed (\(count)) — \(output.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
                refresh?()
            }
        }
    }
}
