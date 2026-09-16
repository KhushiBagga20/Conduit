//
//  LinkServerTests.swift
//  ConduitCoreTests
//
//  The listener, over a real socket on this Mac: a phone dials in, pairs with
//  the six-digit code, and sends a sealed message that arrives as an envelope.
//  Everything here is the shipping code apart from the phone, which speaks the
//  spec directly — the same thing Conduit for Android has to do.
//

import ConduitProtocol
import CryptoKit
import Foundation
import Network
import Testing
@testable import ConduitCore

/// A phone that talks to the listener over TCP.
@MainActor
private final class SocketPhone {

    let identity = P256.Signing.PrivateKey()
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let nonce = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) })

    private let connection: NWConnection
    private var decoder = FrameDecoder()
    private var sealer: LinkCrypto.Sealer?
    private var opener: LinkCrypto.Opener?
    private var transcript = Data()
    private var macEphemeral = Data()
    private var macIdentity = Data()
    private var macNonce = Data()
    private var incoming: [HandshakeMessage] = []
    private var waiting: CheckedContinuation<HandshakeMessage, Never>?

    var deviceID: String { LinkCrypto.deviceID(forPublicKey: identity.publicKey.x963Representation) }

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func start() {
        connection.start(queue: .main)
        receive()
    }

    func stop() { connection.cancel() }

    /// Send the hello and keep the bytes: the transcript hashes them.
    func sendHello(intent: HandshakeIntent) throws -> Data {
        var hello = HandshakeMessage(step: .hello)
        hello.versions = [ProtocolVersion.current]
        hello.device = DeviceInfo(id: deviceID, name: "S24 Ultra", model: "SM-S928B",
                                  manufacturer: "samsung", platform: .android, osVersion: "16")
        hello.identityKey = identity.publicKey.x963Representation.base64EncodedString()
        hello.ephemeralKey = ephemeral.publicKey.x963Representation.base64EncodedString()
        hello.intent = intent
        let payload = try hello.encoded()
        send(payload, type: ControlType.handshake.rawValue, sealed: false)
        return payload
    }

    func receiveMacHello(ourHello: Data) async throws {
        let message = await next()
        #expect(message.step == .hello)
        let payload = try message.encoded()
        macEphemeral = try #require(message.ephemeralKey.flatMap { Data(base64Encoded: $0) })
        macIdentity = try #require(message.identityKey.flatMap { Data(base64Encoded: $0) })

        let macKey = try P256.KeyAgreement.PublicKey(x963Representation: macEphemeral)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: macKey)
        transcript = LinkCrypto.transcript(phoneHello: ourHello, macHello: payload)
        let keys = LinkCrypto.sessionKeys(sharedSecret: shared, transcript: transcript)
        sealer = LinkCrypto.Sealer(key: keys.phoneToMac)
        opener = LinkCrypto.Opener(key: keys.macToPhone)
    }

    func pair() async throws -> String {
        var nonceMessage = HandshakeMessage(step: .pairNonce)
        nonceMessage.nonce = nonce.base64EncodedString()
        send(try nonceMessage.encoded(), type: ControlType.handshake.rawValue, sealed: true)

        let reveal = await next()
        #expect(reveal.step == .pairReveal)
        macNonce = try #require(reveal.nonce.flatMap { Data(base64Encoded: $0) })

        var confirm = HandshakeMessage(step: .pairConfirm)
        confirm.signature = try LinkCrypto.sign(
            LinkCrypto.pairStatement(role: .phone, transcript: transcript, phoneNonce: nonce, macNonce: macNonce),
            with: identity).base64EncodedString()
        send(try confirm.encoded(), type: ControlType.handshake.rawValue, sealed: true)

        return LinkCrypto.pairingCode(phoneEphemeral: ephemeral.publicKey.x963Representation,
                                      macEphemeral: macEphemeral, phoneNonce: nonce, macNonce: macNonce)
    }

    /// The Mac confirms too, and the phone checks that signature before it
    /// trusts the Mac — then `ready` closes the handshake.
    func awaitReady() async {
        while true {
            let message = await next()
            switch message.step {
            case .pairConfirm:
                let signature = message.signature.flatMap { Data(base64Encoded: $0) }
                #expect(signature.map {
                    LinkCrypto.verify($0, of: LinkCrypto.pairStatement(role: .mac, transcript: transcript,
                                                                       phoneNonce: nonce, macNonce: macNonce),
                                      by: macIdentity)
                } == true)
            case .ready:
                return
            default:
                Issue.record("unexpected handshake step \(message.step)")
                return
            }
        }
    }

    func send(_ envelope: Envelope) throws {
        send(try envelope.encoded(), type: ControlType.envelope.rawValue, sealed: true)
    }

    // MARK: - Plumbing

    private func send(_ payload: Data, type: UInt8, sealed: Bool) {
        var body = payload
        if sealed, let out = try? sealer?.seal(payload, channel: LinkChannel.control.rawValue, type: type) {
            body = out
        }
        connection.send(content: Frame(channel: .control, type: type, payload: body).encoded(),
                        completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty, let frames = try? decoder.receive(data) {
                    for frame in frames {
                        var payload = frame.payload
                        if opener != nil, let opened = try? opener?.open(frame.payload, channel: frame.channel.rawValue,
                                                                        type: frame.type) {
                            payload = opened
                        }
                        if let message = try? HandshakeMessage.decode(payload) { deliver(message) }
                    }
                }
                if !isComplete, error == nil { receive() }
            }
        }
    }

    private func deliver(_ message: HandshakeMessage) {
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: message)
        } else {
            incoming.append(message)
        }
    }

    private func next() async -> HandshakeMessage {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return await withCheckedContinuation { continuation in waiting = continuation }
    }
}

@Suite("Conduit Link server")
@MainActor
struct LinkServerTests {

    @Test("a phone dials in, pairs, and its messages arrive as envelopes", .timeLimit(.minutes(1)))
    func pairsOverASocket() async throws {
        let defaults = UserDefaults(suiteName: "conduit.tests.\(UUID().uuidString)")!
        let identity = LinkIdentity(signingKey: P256.Signing.PrivateKey())
        let trust = LinkTrust(defaults: defaults)
        let server = LinkServer(identity: identity, trust: trust) {
            identity.deviceInfo(name: "Test Mac", appVersion: "0.1.0")
        }
        server.pairingOpen = true

        let listening = Waiter<UInt16>()
        let paired = Waiter<LinkPeer>()
        let received = Waiter<Envelope>()
        var shownCode: String?

        server.onListening = { port, _ in if let port { listening.send(port) } }
        server.onPairing = { connection, request in
            shownCode = request.code
            connection.confirmPairing()
        }
        server.onReady = { peer in paired.send(peer) }
        server.onEnvelope = { envelope, _ in received.send(envelope) }

        server.start()
        defer { server.stop() }
        let port = await listening.value()

        let phone = SocketPhone(port: port)
        phone.start()
        defer { phone.stop() }

        let hello = try phone.sendHello(intent: .pair)
        try await phone.receiveMacHello(ourHello: hello)
        let phoneCode = try await phone.pair()
        await phone.awaitReady()

        let peer = await paired.value()
        #expect(peer.id == phone.deviceID)
        #expect(shownCode == phoneCode)
        #expect(trust.trusts(id: phone.deviceID, publicKey: phone.identity.publicKey.x963Representation))

        try phone.send(Envelope.command(.linkSend, payload: ["url": .string("https://example.com")]))
        let envelope = await received.value()
        if case .command(_, let action) = envelope.kind {
            #expect(action == .linkSend)
            #expect(envelope.payload?["url"] == .string("https://example.com"))
        } else {
            Issue.record("expected a command")
        }
    }
}

/// Waits for one value from a callback.
@MainActor
private final class Waiter<Value: Sendable> {
    private var stored: Value?
    private var waiting: CheckedContinuation<Value, Never>?

    func send(_ value: Value) {
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: value)
        } else {
            stored = value
        }
    }

    func value() async -> Value {
        if let stored {
            self.stored = nil
            return stored
        }
        return await withCheckedContinuation { continuation in waiting = continuation }
    }
}
