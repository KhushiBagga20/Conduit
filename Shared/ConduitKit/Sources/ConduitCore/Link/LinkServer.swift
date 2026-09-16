//
//  LinkServer.swift
//  ConduitCore
//
//  The Mac's side of Conduit Link: a TCP listener and a Bonjour advert that
//  phones dial into.
//
//  The Mac listens and the phone connects, because the phone is the one that
//  moves between networks — including its own hotspot, where it is the
//  network. The advert carries only this Mac's device ID and the protocol
//  version; the handshake proves who is who.
//

import ConduitMedia
import ConduitProtocol
import Foundation
import Network

@MainActor
final class LinkServer {

    /// The spec's preferred port. Any free port will do if it is taken.
    static let preferredPort: UInt16 = 47384
    static let serviceType = "_conduit._tcp"

    private let identity: LinkIdentity
    private let trust: LinkTrust
    private let device: () -> DeviceInfo
    private let port: UInt16

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: LinkConnection] = [:]

    /// True while the person is adding a phone: only then will this Mac pair
    /// with one it does not know.
    var pairingOpen = false

    /// The port, and whether the Bonjour advert is up. macOS blocks the
    /// advert until Conduit is allowed on the local network; the port still
    /// works, and phones can be told where to find it over adb.
    var onListening: (UInt16?, Bool) -> Void = { _, _ in }
    var onPairing: (LinkConnection, LinkConnection.PairingRequest) -> Void = { _, _ in }
    var onReady: (LinkPeer) -> Void = { _ in }
    var onEnvelope: (Envelope, LinkPeer) -> Void = { _, _ in }
    var onClosed: (LinkPeer?, ProtocolError?) -> Void = { _, _ in }

    /// `port` 0 takes any free port.
    init(identity: LinkIdentity, trust: LinkTrust, port: UInt16 = LinkServer.preferredPort,
         device: @escaping () -> DeviceInfo) {
        self.identity = identity
        self.trust = trust
        self.port = port
        self.device = device
    }

    func start() { start(on: port, advertising: true) }

    private func start(on port: UInt16, advertising: Bool) {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any) else {
            CoreLog.engine.error("Conduit Link could not open a port")
            onListening(nil, false)
            return
        }

        if advertising {
            listener.service = NWListener.Service(
                name: device().name, type: Self.serviceType,
                txtRecord: NWTXTRecord(["id": identity.deviceID, "v": String(ProtocolVersion.current)]))
        }

        listener.stateUpdateHandler = { state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = listener.port?.rawValue
                    CoreLog.engine.notice("Conduit Link is listening on port \(port ?? 0)")
                    onListening(port, advertising)
                case .failed(let error):
                    // macOS refuses the Bonjour advert until Conduit is
                    // allowed on the local network. The port itself is fine,
                    // so listen without the advert rather than not at all.
                    if advertising, Self.isLocalNetworkRefusal(error) {
                        CoreLog.engine.error("macOS is blocking Conduit Link's Bonjour advert; listening without it")
                        stopListener()
                        start(on: port, advertising: false)
                        return
                    }
                    // MEASURED: a port already in use does not fail when the
                    // listener is created, only once it starts. The advert
                    // carries the real port, so any free one will do.
                    if port != 0, Self.isAddressInUse(error) {
                        CoreLog.engine.notice("port \(port) is taken; Conduit Link is taking any free port")
                        stopListener()
                        start(on: 0, advertising: advertising)
                        return
                    }
                    CoreLog.engine.error("Conduit Link stopped listening — \(error.localizedDescription)")
                    stop()
                    onListening(nil, false)
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }

        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        for connection in connections.values { connection.close() }
        connections.removeAll()
        stopListener()
        onListening(nil, false)
    }

    private func stopListener() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }

    private static func isAddressInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error { return code == .EADDRINUSE }
        return false
    }

    /// `NoAuth` from the DNS responder: the app may not use the local network.
    private static func isLocalNetworkRefusal(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65555 }
        return false
    }

    /// Close a paired phone's connection, after it has been forgotten.
    func disconnect(peerID: String) {
        for (key, connection) in connections where connection.peerID == peerID {
            connection.close(ProtocolError(.notPaired, "This Mac no longer pairs with that phone."))
            connections[key] = nil
        }
    }

    func send(_ envelope: Envelope, to peerID: String) {
        for connection in connections.values where connection.peerID == peerID {
            connection.send(envelope)
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = LinkConnection(connection: nwConnection, identity: identity, device: device(),
                                        trust: trust, pairingOpen: pairingOpen)
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        connection.onPairing = { [weak self] request in self?.onPairing(connection, request) }
        connection.onReady = { [weak self] peer in
            guard let self else { return }
            // One connection per phone: a phone that reconnects after a
            // network change replaces its own earlier one.
            for (other, existing) in connections where other != key && existing.peerID == peer.id {
                existing.close()
                connections[other] = nil
            }
            onReady(peer)
        }
        connection.onEnvelope = { [weak self] envelope, peer in self?.onEnvelope(envelope, peer) }
        connection.onClosed = { [weak self] peer, error in
            guard let self else { return }
            connections[key] = nil
            onClosed(peer, error)
        }
        connection.start()
    }
}
