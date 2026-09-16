//
//  LinkVectorTests.swift
//  ConduitCoreTests
//
//  The handshake vectors in Shared/Protocol/vectors, which Conduit for
//  Android runs too. A value that drifts here is a protocol break.
//

import CryptoKit
import Foundation
import Testing
@testable import ConduitCore

@Suite("Conduit Link vectors")
struct LinkVectorTests {

    private let vectors: [String: Any]

    init() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Protocol/vectors/handshake.json")
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        vectors = parsed ?? [:]
    }

    private func section(_ name: String) -> [String: Any] {
        vectors[name] as? [String: Any] ?? [:]
    }

    private func value(_ name: String, _ key: String) -> String {
        section(name)[key] as? String ?? ""
    }

    private func data(_ name: String, _ key: String) -> Data {
        Self.data(fromHex: value(name, key))
    }

    private static func data(fromHex string: String) -> Data {
        var bytes = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            if let byte = UInt8(string[index ..< next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return bytes
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func hex(_ key: SymmetricKey) -> String {
        hex(key.withUnsafeBytes { Data($0) })
    }

    @Test("the key schedule, the statements, the pairing code and the device ID")
    func schedule() throws {
        let phone = try P256.KeyAgreement.PrivateKey(rawRepresentation: data("ephemeral", "phonePrivate"))
        let macPublic = try P256.KeyAgreement.PublicKey(x963Representation: data("ephemeral", "macPublic"))
        let shared = try phone.sharedSecretFromKeyAgreement(with: macPublic)
        let sharedHex = hex(shared.withUnsafeBytes { Data($0) })

        #expect(sharedHex == value("ephemeral", "sharedSecret"))
        #expect(hex(phone.publicKey.x963Representation) == value("ephemeral", "phonePublic"))

        let transcript = LinkCrypto.transcript(phoneHello: data("hellos", "phone"), macHello: data("hellos", "mac"))
        let expectedTranscript = vectors["transcript"] as? String ?? ""
        #expect(hex(transcript) == expectedTranscript)

        let keys = LinkCrypto.sessionKeys(sharedSecret: shared, transcript: transcript)
        #expect(hex(keys.phoneToMac) == value("sessionKeys", "phoneToMac"))
        #expect(hex(keys.macToPhone) == value("sessionKeys", "macToPhone"))

        let phoneNonce = data("pairing", "phoneNonce")
        let macNonce = data("pairing", "macNonce")
        let authPhone = LinkCrypto.authStatement(role: .phone, transcript: transcript)
        let pairMac = LinkCrypto.pairStatement(role: .mac, transcript: transcript,
                                               phoneNonce: phoneNonce, macNonce: macNonce)
        #expect(hex(authPhone) == value("statements", "authPhone"))
        #expect(hex(pairMac) == value("statements", "pairMac"))

        let phoneEphemeral = data("ephemeral", "phonePublic")
        let macEphemeral = data("ephemeral", "macPublic")
        let commitment = LinkCrypto.pairCommitment(macNonce: macNonce, phoneEphemeral: phoneEphemeral,
                                                   macEphemeral: macEphemeral)
        let code = LinkCrypto.pairingCode(phoneEphemeral: phoneEphemeral, macEphemeral: macEphemeral,
                                          phoneNonce: phoneNonce, macNonce: macNonce)
        #expect(hex(commitment) == value("pairing", "commitment"))
        #expect(code == value("pairing", "code"))
        #expect(LinkCrypto.deviceID(forPublicKey: data("deviceID", "publicKey")) == value("deviceID", "id"))
    }

    @Test("sealed frames, byte for byte")
    func sealedFrames() throws {
        let key = SymmetricKey(data: data("sessionKeys", "phoneToMac"))
        var sealer = LinkCrypto.Sealer(key: key)
        var opener = LinkCrypto.Opener(key: key)

        let frames = vectors["sealed"] as? [[String: Any]] ?? []
        #expect(frames.count == 2)

        for frame in frames {
            let channel = UInt8(frame["channel"] as? Int ?? 0)
            let type = UInt8(frame["type"] as? Int ?? 0)
            let plaintext = Self.data(fromHex: frame["plaintext"] as? String ?? "")
            let expected = frame["payload"] as? String ?? ""

            let sealed = try sealer.seal(plaintext, channel: channel, type: type)
            #expect(hex(sealed) == expected)

            let opened = try opener.open(Self.data(fromHex: expected), channel: channel, type: type)
            #expect(opened == plaintext)
        }
    }
}
