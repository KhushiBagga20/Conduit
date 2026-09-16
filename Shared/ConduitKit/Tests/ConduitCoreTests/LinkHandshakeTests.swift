//
//  LinkHandshakeTests.swift
//  ConduitCoreTests
//
//  The Conduit Link handshake, driven by a phone written here against the
//  real Mac implementation: pairing with the six-digit code, reconnecting
//  afterwards, and every way it is meant to refuse. Conduit for Android has
//  to agree with this byte for byte, so the phone side follows the spec
//  rather than calling into the Mac's own steps.
//

import ConduitProtocol
import CryptoKit
import Foundation
import Testing
@testable import ConduitCore

/// The phone's side of the handshake, as Shared/Protocol/README.md §5 states it.
@MainActor
private final class TestPhone {

    let identity = P256.Signing.PrivateKey()
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let nonce = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })

    private(set) var transcript = Data()
    private(set) var keys: LinkCrypto.SessionKeys?
    private(set) var macEphemeral = Data()
    private(set) var commitment: Data?

    var deviceID: String { LinkCrypto.deviceID(forPublicKey: identity.publicKey.x963Representation) }

    var device: DeviceInfo {
        DeviceInfo(id: deviceID, name: "S24 Ultra", model: "SM-S928B", manufacturer: "samsung",
                   platform: .android, osVersion: "16", appVersion: "0.1.0")
    }

    func hello(intent: HandshakeIntent, versions: [Int] = [ProtocolVersion.current]) throws -> Data {
        var hello = HandshakeMessage(step: .hello)
        hello.versions = versions
        hello.device = device
        hello.identityKey = identity.publicKey.x963Representation.base64EncodedString()
        hello.ephemeralKey = ephemeral.publicKey.x963Representation.base64EncodedString()
        hello.intent = intent
        return try hello.encoded()
    }

    /// Derive the same keys the Mac derived, from the bytes it actually sent.
    func receive(macHello payload: Data, ourHello: Data) throws {
        let message = try HandshakeMessage.decode(payload)
        macEphemeral = try #require(message.ephemeralKey.flatMap { Data(base64Encoded: $0) })
        commitment = message.commitment.flatMap { Data(base64Encoded: $0) }

        let macKey = try P256.KeyAgreement.PublicKey(x963Representation: macEphemeral)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: macKey)
        transcript = LinkCrypto.transcript(phoneHello: ourHello, macHello: payload)
        keys = LinkCrypto.sessionKeys(sharedSecret: shared, transcript: transcript)
    }

    func auth() throws -> Data {
        var auth = HandshakeMessage(step: .auth)
        auth.signature = try LinkCrypto.sign(LinkCrypto.authStatement(role: .phone, transcript: transcript),
                                             with: identity).base64EncodedString()
        return try auth.encoded()
    }

    func pairNonce() throws -> Data {
        var message = HandshakeMessage(step: .pairNonce)
        message.nonce = nonce.base64EncodedString()
        return try message.encoded()
    }

    func pairConfirm(macNonce: Data) throws -> Data {
        var message = HandshakeMessage(step: .pairConfirm)
        let statement = LinkCrypto.pairStatement(role: .phone, transcript: transcript,
                                                 phoneNonce: nonce, macNonce: macNonce)
        message.signature = try LinkCrypto.sign(statement, with: identity).base64EncodedString()
        return try message.encoded()
    }

    func code(macNonce: Data) -> String {
        LinkCrypto.pairingCode(phoneEphemeral: ephemeral.publicKey.x963Representation,
                               macEphemeral: macEphemeral, phoneNonce: nonce, macNonce: macNonce)
    }
}

@MainActor
private struct Mac {
    let identity = LinkIdentity(signingKey: P256.Signing.PrivateKey())
    let trust: LinkTrust
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: "conduit.tests.\(UUID().uuidString)")!
        trust = LinkTrust(defaults: defaults)
    }

    func handshake(pairingOpen: Bool) -> LinkHandshake {
        LinkHandshake(identity: identity,
                      device: identity.deviceInfo(name: "Khushi's MacBook", appVersion: "0.1.0"),
                      trust: trust, pairingOpen: pairingOpen)
    }
}

// Reading the actions a step produced.
private extension Array where Element == LinkHandshake.Action {
    func payload(_ step: HandshakeStep) -> Data? {
        for case .send(let sent, let payload, _) in self where sent == step { return payload }
        return nil
    }

    var pairingCode: String? {
        for case .confirmPairing(let code, _) in self { return code }
        return nil
    }

    var ready: LinkPeer? {
        for case .ready(let peer) in self { return peer }
        return nil
    }

    var keys: LinkCrypto.SessionKeys? {
        for case .keysEstablished(let keys) in self { return keys }
        return nil
    }

    var failure: ProtocolError? {
        for case .fail(let error) in self { return error }
        return nil
    }

    var sealedSteps: [HandshakeStep] {
        compactMap { if case .send(let step, _, let sealed) = $0, sealed { return step } else { return nil } }
    }
}

@Suite("Conduit Link handshake")
@MainActor
struct LinkHandshakeTests {

    @Test("pairing: both sides show the same six digits, and the phone is remembered")
    func pairing() throws {
        let mac = Mac()
        let phone = TestPhone()
        let handshake = mac.handshake(pairingOpen: true)

        let phoneHello = try phone.hello(intent: .pair)
        let afterHello = handshake.receive(try HandshakeMessage.decode(phoneHello), raw: phoneHello)
        let macHello = try #require(afterHello.payload(.hello))
        try phone.receive(macHello: macHello, ourHello: phoneHello)

        // The Mac commits to its nonce before it has seen the phone's.
        let commitment = try #require(phone.commitment)

        let nonceMessage = try phone.pairNonce()
        let afterNonce = handshake.receive(try HandshakeMessage.decode(nonceMessage), raw: nonceMessage)
        let reveal = try HandshakeMessage.decode(try #require(afterNonce.payload(.pairReveal)))
        let macNonce = try #require(reveal.nonce.flatMap { Data(base64Encoded: $0) })

        #expect(LinkCrypto.pairCommitment(macNonce: macNonce,
                                          phoneEphemeral: phone.ephemeral.publicKey.x963Representation,
                                          macEphemeral: phone.macEphemeral) == commitment)

        let shown = try #require(afterNonce.pairingCode)
        #expect(shown == phone.code(macNonce: macNonce))
        #expect(shown.count == 6 && shown.allSatisfy(\.isNumber))

        // Neither side finishes until both the person and the phone confirm.
        let confirmed = handshake.confirmPairing()
        #expect(confirmed.ready == nil)
        let phoneConfirm = try phone.pairConfirm(macNonce: macNonce)
        let finished = handshake.receive(try HandshakeMessage.decode(phoneConfirm), raw: phoneConfirm)

        let ready = try #require(finished.ready)
        #expect(ready.id == phone.deviceID)
        #expect(mac.trust.trusts(id: phone.deviceID, publicKey: phone.identity.publicKey.x963Representation))
        #expect(finished.payload(.ready) != nil)

        // Everything after the two hellos is sealed.
        #expect(afterNonce.sealedSteps.contains(.pairReveal))
        #expect(finished.sealedSteps.contains(.ready))

        // Both sides hold the same keys, in both directions.
        var sealer = LinkCrypto.Sealer(key: try #require(phone.keys).phoneToMac)
        var opener = LinkCrypto.Opener(key: try #require(afterHello.keys).phoneToMac)
        let sealed = try sealer.seal(Data("hello mac".utf8), channel: 0, type: 1)
        #expect(try opener.open(sealed, channel: 0, type: 1) == Data("hello mac".utf8))
    }

    @Test("a paired phone reconnects without pairing again")
    func reconnect() throws {
        let mac = Mac()
        let phone = TestPhone()
        mac.trust.remember(LinkPeer(id: phone.deviceID, name: "S24 Ultra", platform: .android,
                                    publicKey: phone.identity.publicKey.x963Representation, lastSeen: .distantPast))

        let handshake = mac.handshake(pairingOpen: false)
        let phoneHello = try phone.hello(intent: .connect)
        let afterHello = handshake.receive(try HandshakeMessage.decode(phoneHello), raw: phoneHello)
        let macHello = try #require(afterHello.payload(.hello))
        try phone.receive(macHello: macHello, ourHello: phoneHello)

        // The Mac proves itself first, over the same transcript.
        let macAuth = try HandshakeMessage.decode(try #require(afterHello.payload(.auth)))
        let signature = try #require(macAuth.signature.flatMap { Data(base64Encoded: $0) })
        #expect(LinkCrypto.verify(signature,
                                  of: LinkCrypto.authStatement(role: .mac, transcript: phone.transcript),
                                  by: mac.identity.publicKey))

        let phoneAuth = try phone.auth()
        let finished = handshake.receive(try HandshakeMessage.decode(phoneAuth), raw: phoneAuth)
        #expect(finished.ready?.id == phone.deviceID)

        let ready = try HandshakeMessage.decode(try #require(finished.payload(.ready)))
        #expect(ready.session?.heartbeatSeconds == 15)
    }

    @Test("an unknown phone is refused unless this Mac is pairing")
    func refusesStrangers() throws {
        let mac = Mac()
        let phone = TestPhone()
        let handshake = mac.handshake(pairingOpen: false)

        let hello = try phone.hello(intent: .connect)
        let actions = handshake.receive(try HandshakeMessage.decode(hello), raw: hello)
        #expect(actions.failure?.code == .notPaired)
        #expect(mac.trust.peers.isEmpty)
    }

    @Test("a wrong signature, a mismatched device ID and an unknown version are all refused")
    func refusesBadProof() throws {
        // A phone whose signature is made with a different key.
        let mac = Mac()
        let phone = TestPhone()
        mac.trust.remember(LinkPeer(id: phone.deviceID, name: "S24 Ultra", platform: .android,
                                    publicKey: phone.identity.publicKey.x963Representation, lastSeen: .distantPast))
        let handshake = mac.handshake(pairingOpen: false)
        let hello = try phone.hello(intent: .connect)
        let afterHello = handshake.receive(try HandshakeMessage.decode(hello), raw: hello)
        try phone.receive(macHello: try #require(afterHello.payload(.hello)), ourHello: hello)

        var forged = HandshakeMessage(step: .auth)
        let impostor = P256.Signing.PrivateKey()
        forged.signature = try LinkCrypto.sign(
            LinkCrypto.authStatement(role: .phone, transcript: phone.transcript), with: impostor)
            .base64EncodedString()
        let forgedPayload = try forged.encoded()
        #expect(handshake.receive(try HandshakeMessage.decode(forgedPayload), raw: forgedPayload).failure?.code == .notPaired)

        // A hello whose device ID is not the one its key hashes to.
        let liar = TestPhone()
        var claim = try HandshakeMessage.decode(try liar.hello(intent: .pair))
        claim.device?.id = String(repeating: "a", count: 32)
        let claimPayload = try claim.encoded()
        let second = Mac().handshake(pairingOpen: true)
        #expect(second.receive(try HandshakeMessage.decode(claimPayload), raw: claimPayload).failure?.code == .invalidRequest)

        // A phone that speaks no version this Mac does.
        let ancient = TestPhone()
        let old = try ancient.hello(intent: .pair, versions: [0])
        let third = Mac().handshake(pairingOpen: true)
        #expect(third.receive(try HandshakeMessage.decode(old), raw: old).failure?.code == .versionMismatch)
    }

    @Test("sealed frames are bound to their channel, in order")
    func sealedFrames() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = LinkCrypto.Sealer(key: key)
        var opener = LinkCrypto.Opener(key: key)

        let first = try sealer.seal(Data("one".utf8), channel: 0, type: 1)
        let second = try sealer.seal(Data("two".utf8), channel: 1, type: 0)

        // The same plaintext never seals the same way twice: the counter moves.
        #expect(try sealer.seal(Data("one".utf8), channel: 0, type: 1) != first)
        // A frame replayed on another channel does not open.
        #expect(throws: LinkCryptoError.openFailed) { var wrong = opener; _ = try wrong.open(first, channel: 2, type: 1) }
        // Out of order does not open either.
        #expect(throws: LinkCryptoError.openFailed) { var ahead = opener; _ = try ahead.open(second, channel: 1, type: 0) }

        #expect(try opener.open(first, channel: 0, type: 1) == Data("one".utf8))
        #expect(try opener.open(second, channel: 1, type: 0) == Data("two".utf8))
    }
}
