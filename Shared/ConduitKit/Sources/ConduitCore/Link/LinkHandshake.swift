//
//  LinkHandshake.swift
//  ConduitCore
//
//  The Mac's side of the Conduit Link handshake — Shared/Protocol/README.md
//  §5 — as a state machine with no sockets in it, so every path can be tested
//  against a phone written in the tests.
//
//  It answers a phone's hello, derives the session keys, proves this Mac's
//  identity, and where the phone is new, runs the six-digit pairing both
//  people compare. Nothing is trusted until a signature over the transcript
//  verifies: a tampered negotiation cannot survive it.
//

import ConduitProtocol
import CryptoKit
import Foundation

@MainActor
final class LinkHandshake {

    /// What the connection should do next. `sealed` frames go out under the
    /// session keys; the two hellos are plaintext.
    enum Action {
        /// Exactly the bytes to put on the wire: the transcript hashes these,
        /// so they are never re-encoded on the way out.
        case send(step: HandshakeStep, payload: Data, sealed: Bool)
        /// The session keys exist: everything sent from here on is sealed.
        case keysEstablished(LinkCrypto.SessionKeys)
        case confirmPairing(code: String, device: DeviceInfo)
        case ready(peer: LinkPeer)
        case fail(ProtocolError)
    }

    private enum Step {
        case awaitingHello
        case awaitingAuth
        case awaitingPairNonce
        case pairing
        case done
        case failed
    }

    private let identity: LinkIdentity
    private let device: DeviceInfo
    private let trust: LinkTrust
    /// Whether this Mac is currently willing to pair with a new phone.
    private let pairingOpen: Bool
    private let heartbeatSeconds: Int

    private var step: Step = .awaitingHello
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private let macNonce: Data

    private var phoneEphemeral = Data()
    private var phoneIdentityKey = Data()
    private var phoneDevice: DeviceInfo?
    private var phoneNonce = Data()
    private var transcript = Data()
    private var keys: LinkCrypto.SessionKeys?
    private var userConfirmed = false
    private var phoneConfirmed = false

    init(identity: LinkIdentity, device: DeviceInfo, trust: LinkTrust,
         pairingOpen: Bool, heartbeatSeconds: Int = 15) {
        self.identity = identity
        self.device = device
        self.trust = trust
        self.pairingOpen = pairingOpen
        self.heartbeatSeconds = heartbeatSeconds
        macNonce = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })
    }

    // MARK: - Incoming

    /// `raw` is the payload exactly as it arrived: the transcript hashes the
    /// bytes on the wire, not a re-encoding of them.
    func receive(_ message: HandshakeMessage, raw: Data) -> [Action] {
        switch (step, message.step) {
        case (.awaitingHello, .hello):
            return hello(message, raw: raw)
        case (.awaitingAuth, .auth):
            return authenticated(message)
        case (.awaitingPairNonce, .pairNonce):
            return pairNonce(message)
        case (.pairing, .pairConfirm):
            return pairConfirm(message)
        case (_, .pairReject):
            return fail(ProtocolError(.cancelled, "The phone cancelled pairing."))
        case (_, .error):
            return fail(message.error ?? ProtocolError(.internal, "The phone reported an error."))
        default:
            return fail(ProtocolError(.invalidRequest, "Unexpected handshake step."))
        }
    }

    /// The person compared the code on this Mac and said yes.
    func confirmPairing() -> [Action] {
        guard step == .pairing, !userConfirmed else { return [] }
        userConfirmed = true

        var confirm = HandshakeMessage(step: .pairConfirm)
        let statement = LinkCrypto.pairStatement(role: .mac, transcript: transcript,
                                                 phoneNonce: phoneNonce, macNonce: macNonce)
        guard let signature = try? LinkCrypto.sign(statement, with: identity.signingKey) else {
            return fail(ProtocolError(.internal, "This Mac could not sign the pairing."))
        }
        confirm.signature = signature.base64EncodedString()
        guard let action = sending(confirm, sealed: true) else {
            return fail(ProtocolError(.internal, "This Mac could not encode the pairing."))
        }
        return [action] + finishPairingIfReady()
    }

    func rejectPairing() -> [Action] {
        guard step == .pairing else { return [] }
        step = .failed
        let refused = ProtocolError(.cancelled, "Pairing was refused on this Mac.")
        guard let action = sending(HandshakeMessage(step: .pairReject), sealed: true) else { return [.fail(refused)] }
        return [action, .fail(refused)]
    }

    // MARK: - Steps

    private func hello(_ message: HandshakeMessage, raw: Data) -> [Action] {
        guard let versions = message.versions, versions.contains(ProtocolVersion.current),
              let phoneDevice = message.device,
              let identityKey = message.identityKey.flatMap({ Data(base64Encoded: $0) }),
              let ephemeralKey = message.ephemeralKey.flatMap({ Data(base64Encoded: $0) }),
              let peerEphemeral = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralKey)
        else {
            return fail(ProtocolError(.versionMismatch, "This phone speaks a Conduit Link version this Mac does not."))
        }
        guard LinkCrypto.deviceID(forPublicKey: identityKey) == phoneDevice.id else {
            return fail(ProtocolError(.invalidRequest, "The phone's device ID does not match its key."))
        }

        self.phoneDevice = phoneDevice
        phoneIdentityKey = identityKey
        phoneEphemeral = ephemeralKey

        let trusted = trust.trusts(id: phoneDevice.id, publicKey: identityKey)
        let mode: HandshakeMode
        switch (trusted, message.intent ?? .connect, pairingOpen) {
        case (true, .connect, _):
            mode = .authenticate
        case (_, .pair, true), (false, _, true):
            mode = .pair
        default:
            return fail(ProtocolError(.notPaired, "This phone is not paired with this Mac yet."))
        }

        var hello = HandshakeMessage(step: .hello)
        hello.versions = [ProtocolVersion.current]
        hello.version = ProtocolVersion.current
        hello.device = device
        hello.identityKey = identity.publicKey.base64EncodedString()
        hello.ephemeralKey = ephemeral.publicKey.x963Representation.base64EncodedString()
        hello.mode = mode
        if mode == .pair {
            hello.commitment = LinkCrypto.pairCommitment(
                macNonce: macNonce, phoneEphemeral: phoneEphemeral,
                macEphemeral: ephemeral.publicKey.x963Representation).base64EncodedString()
        }

        guard let macHello = try? hello.encoded(),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: peerEphemeral)
        else { return fail(ProtocolError(.internal, "This Mac could not start the handshake.")) }

        transcript = LinkCrypto.transcript(phoneHello: raw, macHello: macHello)
        keys = LinkCrypto.sessionKeys(sharedSecret: shared, transcript: transcript)

        var actions: [Action] = [.send(step: .hello, payload: macHello, sealed: false),
                                 .keysEstablished(keys!)]
        if mode == .authenticate {
            step = .awaitingAuth
            guard let auth = signedAuth(), let action = sending(auth, sealed: true) else {
                return fail(ProtocolError(.internal, "This Mac could not sign the handshake."))
            }
            actions.append(action)
        } else {
            step = .awaitingPairNonce
        }
        return actions
    }

    private func authenticated(_ message: HandshakeMessage) -> [Action] {
        guard let signature = message.signature.flatMap({ Data(base64Encoded: $0) }),
              LinkCrypto.verify(signature,
                                of: LinkCrypto.authStatement(role: .phone, transcript: transcript),
                                by: phoneIdentityKey)
        else { return fail(ProtocolError(.notPaired, "The phone could not prove its identity.")) }

        guard let phoneDevice else {
            return fail(ProtocolError(.internal, "The handshake lost its state."))
        }
        trust.seen(id: phoneDevice.id)
        let peer = trust.peer(id: phoneDevice.id)
            ?? LinkPeer(id: phoneDevice.id, name: phoneDevice.name, platform: phoneDevice.platform,
                        publicKey: phoneIdentityKey, lastSeen: Date())
        step = .done
        guard let action = sending(ready(), sealed: true) else {
            return fail(ProtocolError(.internal, "This Mac could not finish the handshake."))
        }
        return [action, .ready(peer: peer)]
    }

    private func pairNonce(_ message: HandshakeMessage) -> [Action] {
        guard let nonce = message.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32,
              let phoneDevice
        else { return fail(ProtocolError(.invalidRequest, "The phone sent no pairing nonce.")) }

        phoneNonce = nonce
        step = .pairing

        var reveal = HandshakeMessage(step: .pairReveal)
        reveal.nonce = macNonce.base64EncodedString()

        let code = LinkCrypto.pairingCode(phoneEphemeral: phoneEphemeral,
                                          macEphemeral: ephemeral.publicKey.x963Representation,
                                          phoneNonce: phoneNonce, macNonce: macNonce)
        guard let action = sending(reveal, sealed: true) else {
            return fail(ProtocolError(.internal, "This Mac could not answer the pairing."))
        }
        return [action, .confirmPairing(code: code, device: phoneDevice)]
    }

    private func pairConfirm(_ message: HandshakeMessage) -> [Action] {
        guard let signature = message.signature.flatMap({ Data(base64Encoded: $0) }),
              LinkCrypto.verify(signature,
                                of: LinkCrypto.pairStatement(role: .phone, transcript: transcript,
                                                             phoneNonce: phoneNonce, macNonce: macNonce),
                                by: phoneIdentityKey)
        else { return fail(ProtocolError(.notPaired, "The phone's pairing signature did not check out.")) }

        phoneConfirmed = true
        return finishPairingIfReady()
    }

    private func finishPairingIfReady() -> [Action] {
        guard userConfirmed, phoneConfirmed, step == .pairing, let phoneDevice else { return [] }

        let peer = LinkPeer(id: phoneDevice.id, name: phoneDevice.name, platform: phoneDevice.platform,
                            publicKey: phoneIdentityKey, lastSeen: Date())
        trust.remember(peer)
        step = .done
        guard let action = sending(ready(), sealed: true) else {
            return fail(ProtocolError(.internal, "This Mac could not finish pairing."))
        }
        return [action, .ready(peer: peer)]
    }

    // MARK: - Helpers

    private func signedAuth() -> HandshakeMessage? {
        var auth = HandshakeMessage(step: .auth)
        guard let signature = try? LinkCrypto.sign(
            LinkCrypto.authStatement(role: .mac, transcript: transcript), with: identity.signingKey)
        else { return nil }
        auth.signature = signature.base64EncodedString()
        return auth
    }

    private func ready() -> HandshakeMessage {
        var ready = HandshakeMessage(step: .ready)
        ready.session = LinkSessionInfo(epoch: UUID().uuidString, heartbeatSeconds: heartbeatSeconds)
        return ready
    }

    private func sending(_ message: HandshakeMessage, sealed: Bool) -> Action? {
        guard let payload = try? message.encoded() else { return nil }
        return .send(step: message.step, payload: payload, sealed: sealed)
    }

    private func fail(_ error: ProtocolError) -> [Action] {
        guard step != .failed else { return [] }
        let sealed = keys != nil
        step = .failed
        var message = HandshakeMessage(step: .error)
        message.error = error
        guard let action = sending(message, sealed: sealed) else { return [.fail(error)] }
        return [action, .fail(error)]
    }
}
