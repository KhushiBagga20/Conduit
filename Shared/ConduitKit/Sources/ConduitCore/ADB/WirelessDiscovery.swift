//
//  WirelessDiscovery.swift
//  ConduitCore
//
//  Finds phones with Wireless debugging on, using macOS's own Bonjour.
//
//  WHY NOT `adb mdns services`
//
//  Measured before Conduit existed: on some networks adb's built-in mDNS
//  browser lists nothing while `dns-sd -B _adb-tls-connect._tcp` shows the
//  phone. Browsing with Network.framework uses the system resolver that
//  demonstrably works, and hands adb a plain `host:port` to connect to.
//

import ConduitMedia
import Foundation
import Network

struct WirelessEndpoint: Sendable, Hashable {
    let serviceName: String
    /// The hardware serial embedded in the service name, if present.
    let hardwareSerial: String?
    let host: String
    let port: UInt16
}

final class WirelessDiscovery {

    /// Called on the main actor with every resolved endpoint currently visible.
    var onChange: (([WirelessEndpoint]) -> Void)?

    /// Called on the main actor when macOS blocks browsing — in practice,
    /// when Local Network access has not been allowed for Conduit.
    var onBlocked: ((String) -> Void)?
    private var reportedBlocked = false

    private var browser: NWBrowser?
    private var resolved: [String: WirelessEndpoint] = [:]
    private var resolving: Set<String> = []
    private var lastResults: Set<NWBrowser.Result> = []

    /// Every resolved endpoint currently advertised.
    var endpoints: [WirelessEndpoint] { Array(resolved.values) }

    func start() {
        guard browser == nil else { return }

        let browser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in self?.update(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                CoreLog.discovery.info("browser ready")
            case .waiting(let error):
                // A browser that is waiting never produces results. The usual
                // cause is Local Network access being denied or not yet granted.
                CoreLog.discovery.error("browser waiting — \(error.localizedDescription)")
                Task { @MainActor [weak self] in self?.reportBlocked(error) }
            case .failed(let error):
                CoreLog.discovery.error("browser failed — \(error.localizedDescription)")
                Task { @MainActor [weak self] in self?.reportBlocked(error) }
            default:
                break
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        CoreLog.discovery.info("browsing for Wireless debugging")
    }

    private func reportBlocked(_ error: NWError) {
        guard !reportedBlocked else { return }
        reportedBlocked = true
        onBlocked?(error.localizedDescription)
    }

    func stop() {
        reportedBlocked = false
        browser?.cancel()
        browser = nil
        resolved.removeAll()
        resolving.removeAll()
        lastResults.removeAll()
    }

    /// Forget a resolved address and resolve the service again. The port
    /// changes whenever Wireless debugging restarts on the phone, while the
    /// service can keep advertising under the same name.
    func refresh(serviceName: String) {
        guard resolved.removeValue(forKey: serviceName) != nil else { return }
        update(lastResults)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        if results != lastResults {
            CoreLog.discovery.info("\(results.count) Wireless debugging service(s) visible")
        }
        lastResults = results
        var visible: Set<String> = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            visible.insert(name)
            if resolved[name] == nil, !resolving.contains(name) {
                resolve(name: name, endpoint: result.endpoint)
            }
        }

        let before = resolved.count
        resolved = resolved.filter { visible.contains($0.key) }
        if resolved.count != before {
            onChange?(endpoints)
        }
    }

    /// Bonjour gives a service, not an address. Opening a TCP connection
    /// resolves it; the remote endpoint is read, and the connection closed
    /// before any TLS is attempted.
    private func resolve(name: String, endpoint: NWEndpoint) {
        resolving.insert(name)

        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)

        let timeout = DispatchWorkItem { [weak self, connection] in
            connection.cancel()
            self?.resolving.remove(name)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)

        connection.stateUpdateHandler = { [weak self, connection] state in
            guard case .ready = state else {
                if case .failed(let error) = state {
                    CoreLog.discovery.error("could not resolve a Wireless debugging service — \(error.localizedDescription)")
                    connection.cancel()
                }
                return
            }
            defer { connection.cancel() }
            guard case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint else { return }

            var address = "\(host)"
            if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }

            Task { @MainActor [weak self] in
                guard let self else { return }
                timeout.cancel()
                self.resolving.remove(name)
                self.resolved[name] = WirelessEndpoint(
                    serviceName: name,
                    hardwareSerial: ADBParsing.hardwareSerialHint(fromServiceName: name),
                    host: address,
                    port: port.rawValue)
                CoreLog.discovery.info("resolved a Wireless debugging endpoint on port \(port.rawValue)")
                self.onChange?(self.endpoints)
            }
        }
        connection.start(queue: .main)
    }
}
