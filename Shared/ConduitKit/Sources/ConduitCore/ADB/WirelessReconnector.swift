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
import ConduitState
import Foundation

final class WirelessReconnector {

    // Wiring, supplied by the engine.
    var isEnabled: () -> Bool = { false }
    var isKnownPhone: (String) -> Bool = { _ in false }
    /// Wi-Fi transports currently attached for a phone, ready or not.
    var wifiTransports: (String) -> [ADBParsing.Device] = { _ in [] }
    var isMirroring: () -> Bool = { false }
    var record: (ActivityEvent) -> Void = { _ in }
    /// Called when `adb connect` succeeds, with the new transport's serial and
    /// the phone it belongs to — known before its properties load.
    var onConnected: (_ serial: String, _ phoneID: String) -> Void = { _, _ in }

    private let adb: ADB
    private let discovery: WirelessDiscovery

    private var failures: [String: Int] = [:]
    private var nextAttempt: [String: Date] = [:]
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

    /// Seconds to wait after a phone's `failures`-th consecutive failure.
    nonisolated static func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(2 * pow(2, Double(failures - 1)), 60)
    }

    /// Connect any known, advertising phone that has no ready Wi-Fi transport.
    func evaluate() {
        guard isEnabled() else { return }
        let now = Date()

        for endpoint in discovery.endpoints {
            // Only phones this Mac already knows: someone else's phone
            // advertising on the same network is not ours to connect to.
            guard let phoneID = endpoint.hardwareSerial, isKnownPhone(phoneID) else { continue }

            let transports = wifiTransports(phoneID)
            if transports.contains(where: \.isReady) {
                failures[phoneID] = nil
                nextAttempt[phoneID] = nil
                continue
            }
            guard !inFlight.contains(phoneID), (nextAttempt[phoneID] ?? .distantPast) <= now else { continue }

            connect(phoneID: phoneID, endpoint: endpoint, stale: transports.map(\.serial))
        }
    }

    private func connect(phoneID: String, endpoint: WirelessEndpoint, stale: [String]) {
        inFlight.insert(phoneID)
        let adb = self.adb
        let target = "\(endpoint.host):\(endpoint.port)"
        CoreLog.engine.notice("connecting to a known phone over Wireless debugging (attempt \((failures[phoneID] ?? 0) + 1))")

        Task {
            var output = await Task.detached { () -> ADB.Output in
                // A transport stuck offline shadows a fresh connection.
                for serial in stale { adb.disconnect(serial) }
                return adb.run(["connect", target], timeout: 12)
            }.value

            // MEASURED: an adb server started before the Mac changed networks
            // (or by an app without Local Network access) answers "No route
            // to host" although Conduit itself just reached the phone's port.
            // Restarting the server from Conduit clears it — once per launch,
            // and never while mirroring, which it would cut.
            if !ADBParsing.connectSucceeded(output.combined), ADBParsing.isNoRouteToHost(output.combined),
               !restartedADBServer, !isMirroring() {
                restartedADBServer = true
                CoreLog.engine.notice("adb cannot reach a phone Conduit can reach; restarting the adb server")
                record(ActivityEvent(kind: .reconnecting, title: "Restarting adb to reach your phone over Wi-Fi"))
                output = await Task.detached { () -> ADB.Output in
                    adb.run(["kill-server"], timeout: 10)
                    adb.startServer()
                    return adb.run(["connect", target], timeout: 12)
                }.value
            }

            inFlight.remove(phoneID)
            if ADBParsing.connectSucceeded(output.combined) {
                CoreLog.engine.notice("connected over Wireless debugging")
                failures[phoneID] = nil
                nextAttempt[phoneID] = nil
                onConnected(target, phoneID)
            } else {
                let count = (failures[phoneID] ?? 0) + 1
                failures[phoneID] = count
                nextAttempt[phoneID] = Date().addingTimeInterval(Self.backoff(afterFailures: count))
                CoreLog.engine.error("Wireless debugging connect failed (\(count)) — \(output.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
                // The port changes whenever Wireless debugging restarts; the
                // cached address may simply be old.
                discovery.refresh(serviceName: endpoint.serviceName)
            }
        }
    }
}
