//
//  LinkConnection.swift
//  ConduitCore
//
//  One phone's connection to this Mac: frames in, frames out, the handshake
//  driven to ready, and sealed envelopes after it.
//
//  The two hellos are plaintext; everything after them is sealed under the
//  session keys, so a frame that fails to open closes the connection rather
//  than being guessed at. The phone dials the Mac, because the phone is the
//  one that roams between networks.
//

import ConduitMedia
import ConduitProtocol
import Foundation
import Network

@MainActor
final class LinkConnection {

    /// Asks the person to compare the six digits before a new phone is trusted.
    struct PairingRequest {
        let code: String
        let device: DeviceInfo
    }

    var onPairing: (PairingRequest) -> Void = { _ in }
    var onReady: (LinkPeer) -> Void = { _ in }
    var onEnvelope: (Envelope, LinkPeer) -> Void = { _, _ in }
    var onClosed: (LinkPeer?, ProtocolError?) -> Void = { _, _ in }

    /// The phone on the other end, once the handshake has proved it.
    var peerID: String? { peer?.id }

    private let connection: NWConnection
    private let handshake: LinkHandshake
    private var decoder = FrameDecoder()
    private var sealer: LinkCrypto.Sealer?
    private var opener: LinkCrypto.Opener?
    private var peer: LinkPeer?
    private var closed = false
    /// Set once a refusal is on its way out: nothing more is read or handled.
    private var closing = false

    init(connection: NWConnection, identity: LinkIdentity, device: DeviceInfo,
         trust: LinkTrust, pairingOpen: Bool) {
        self.connection = connection
        handshake = LinkHandshake(identity: identity, device: device, trust: trust, pairingOpen: pairingOpen)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    finish(ProtocolError(.internal, error.localizedDescription))
                case .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    /// The person compared the code and accepted, or refused.
    func confirmPairing() { perform(handshake.confirmPairing()) }
    func rejectPairing() { perform(handshake.rejectPairing()) }

    func send(_ envelope: Envelope) {
        guard let payload = try? envelope.encoded() else { return }
        send(payload, channel: .control, type: ControlType.envelope.rawValue, sealed: true)
    }

    func close(_ error: ProtocolError? = nil) {
        finish(error)
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !closed, !closing else { return }
                if let data, !data.isEmpty { decode(data) }
                if isComplete || error != nil {
                    finish(error.map { ProtocolError(.internal, $0.localizedDescription) })
                } else {
                    receive()
                }
            }
        }
    }

    private func decode(_ data: Data) {
        let frames: [Frame]
        do {
            frames = try decoder.receive(data)
        } catch {
            // TCP does not reorder or drop bytes, so this is a bug or an
            // impostor. Either way the stream cannot be trusted any more.
            finish(ProtocolError(.invalidRequest, "The phone sent a frame Conduit could not read."))
            return
        }
        for frame in frames where !closed && !closing {
            handle(frame)
        }
    }

    private func handle(_ frame: Frame) {
        guard let payload = plaintext(of: frame) else { return }

        switch (frame.channel, frame.type) {
        case (.control, ControlType.handshake.rawValue):
            guard peer == nil else {
                finish(ProtocolError(.invalidRequest, "The phone tried to hand shake twice."))
                return
            }
            guard let message = try? HandshakeMessage.decode(payload) else {
                finish(ProtocolError(.invalidRequest, "The phone sent an unreadable handshake."))
                return
            }
            perform(handshake.receive(message, raw: payload))

        case (.control, ControlType.envelope.rawValue):
            guard let peer else {
                finish(ProtocolError(.notPaired, "The phone sent messages before the handshake finished."))
                return
            }
            guard let envelope = try? Envelope.decode(payload) else {
                finish(ProtocolError(.invalidRequest, "The phone sent an unreadable message."))
                return
            }
            onEnvelope(envelope, peer)

        default:
            // Channels for input, haptics and files arrive with their
            // features; until then, silence is better than a guess.
            CoreLog.engine.debug("ignoring a Conduit Link frame on channel \(frame.channel.rawValue)")
        }
    }

    /// Frames are plaintext until the session keys exist, and sealed after.
    private func plaintext(of frame: Frame) -> Data? {
        guard opener != nil else { return frame.payload }
        do {
            return try opener?.open(frame.payload, channel: frame.channel.rawValue, type: frame.type)
        } catch {
            finish(ProtocolError(.internal, "A message from the phone could not be opened."))
            return nil
        }
    }

    // MARK: - Sending

    private func perform(_ actions: [LinkHandshake.Action]) {
        for action in actions {
            switch action {
            case .send(_, let payload, let sealed):
                send(payload, channel: .control, type: ControlType.handshake.rawValue, sealed: sealed)
            case .confirmPairing(let code, let device):
                onPairing(PairingRequest(code: code, device: device))
            case .keysEstablished(let keys):
                // From here on the Mac seals with its own key and opens with
                // the phone's.
                sealer = LinkCrypto.Sealer(key: keys.macToPhone)
                opener = LinkCrypto.Opener(key: keys.phoneToMac)
            case .ready(let peer):
                self.peer = peer
                onReady(peer)
            case .fail(let error):
                finishAfterSending(error)
            }
        }
    }

    /// Close once everything queued has gone out. MEASURED: cancelling an
    /// NWConnection drops what it has not yet sent, so a phone that was
    /// refused saw the connection vanish without the error that says why.
    private func finishAfterSending(_ error: ProtocolError?) {
        guard !closed, !closing else { return }
        closing = true
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
                            Task { @MainActor [weak self] in self?.finish(error) }
                        })
    }

    private func send(_ payload: Data, channel: LinkChannel, type: UInt8, sealed: Bool) {
        guard !closed else { return }
        var body = payload
        if sealed {
            do {
                guard let sealed = try sealer?.seal(payload, channel: channel.rawValue, type: type) else {
                    finish(ProtocolError(.internal, "Conduit tried to seal a message before the keys existed."))
                    return
                }
                body = sealed
            } catch {
                finish(ProtocolError(.internal, "Conduit could not seal a message."))
                return
            }
        }
        connection.send(content: Frame(channel: channel, type: type, payload: body).encoded(),
                        completion: .contentProcessed { _ in })
    }

    private func finish(_ error: ProtocolError?) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClosed(peer, error)
    }
}
