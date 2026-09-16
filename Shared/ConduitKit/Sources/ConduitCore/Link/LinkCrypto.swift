//
//  LinkCrypto.swift
//  ConduitCore
//
//  The cryptography of Conduit Link v1, exactly as Shared/Protocol/README.md
//  §5 defines it. Every constant string and byte order here is part of the
//  wire protocol: Conduit for Android computes the same values, and the test
//  vectors in Shared/Protocol/vectors/handshake.json pin them down.
//

import CryptoKit
import Foundation

nonisolated enum LinkRole: String, Sendable {
    case phone
    case mac
}

nonisolated enum LinkCryptoError: Error, Equatable {
    case badKey
    case badSignature
    case sealFailed
    case openFailed
    case counterExhausted
}

nonisolated enum LinkCrypto {

    // MARK: - Key schedule

    /// SHA-256 over both hello payloads, in the order they were sent.
    static func transcript(phoneHello: Data, macHello: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: phoneHello)
        hasher.update(data: macHello)
        return Data(hasher.finalize())
    }

    struct SessionKeys: Sendable {
        let phoneToMac: SymmetricKey
        let macToPhone: SymmetricKey
    }

    /// HKDF-SHA256 over the ECDH secret, salted with the transcript so a
    /// tampered negotiation cannot survive authentication.
    static func sessionKeys(sharedSecret: SharedSecret, transcript: Data) -> SessionKeys {
        let secret = sharedSecret.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        return SessionKeys(
            phoneToMac: derive(secret: secret, transcript: transcript, info: "conduit v1 phone->mac"),
            macToPhone: derive(secret: secret, transcript: transcript, info: "conduit v1 mac->phone"))
    }

    private static func derive(secret: SymmetricKey, transcript: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: transcript,
                               info: Data(info.utf8), outputByteCount: 32)
    }

    // MARK: - Signed statements

    /// `"conduit-auth-v1" ‖ role ‖ th`
    static func authStatement(role: LinkRole, transcript: Data) -> Data {
        Data("conduit-auth-v1".utf8) + Data(role.rawValue.utf8) + transcript
    }

    /// `"conduit-pair-v1" ‖ role ‖ th ‖ Nc ‖ Ns`
    static func pairStatement(role: LinkRole, transcript: Data, phoneNonce: Data, macNonce: Data) -> Data {
        Data("conduit-pair-v1".utf8) + Data(role.rawValue.utf8) + transcript + phoneNonce + macNonce
    }

    static func sign(_ statement: Data, with key: P256.Signing.PrivateKey) throws -> Data {
        try key.signature(for: statement).derRepresentation
    }

    static func verify(_ signature: Data, of statement: Data, by publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else { return false }
        return key.isValidSignature(parsed, for: statement)
    }

    // MARK: - Pairing

    /// HMAC-SHA256(key: the Mac's nonce, message: ephC ‖ ephS). The Mac sends
    /// this before it has seen the phone's nonce.
    static func pairCommitment(macNonce: Data, phoneEphemeral: Data, macEphemeral: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: phoneEphemeral + macEphemeral,
                                                   using: SymmetricKey(data: macNonce))
        return Data(code)
    }

    /// The six digits shown on both devices.
    static func pairingCode(phoneEphemeral: Data, macEphemeral: Data,
                            phoneNonce: Data, macNonce: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("conduit-sas-v1".utf8))
        hasher.update(data: phoneEphemeral)
        hasher.update(data: macEphemeral)
        hasher.update(data: phoneNonce)
        hasher.update(data: macNonce)
        let digest = Data(hasher.finalize())
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    /// The device ID the spec defines: the first 16 bytes of SHA-256 over the
    /// public key, in lowercase hex.
    static func deviceID(forPublicKey publicKey: Data) -> String {
        Data(SHA256.hash(data: publicKey)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sealed frames

    /// AES-256-GCM with one key and one counter per direction. The nonce is
    /// four zero bytes then the counter, big-endian; the frame's channel and
    /// type bytes are the associated data, so a frame cannot be replayed on
    /// another channel.
    struct Sealer {
        private let key: SymmetricKey
        private var counter: UInt64 = 0

        init(key: SymmetricKey) { self.key = key }

        mutating func seal(_ plaintext: Data, channel: UInt8, type: UInt8) throws -> Data {
            guard counter < UInt64.max else { throw LinkCryptoError.counterExhausted }
            let nonce = LinkCrypto.nonce(counter: counter)
            counter += 1
            guard let box = try? AES.GCM.seal(plaintext, using: key,
                                              nonce: try AES.GCM.Nonce(data: nonce),
                                              authenticating: Data([channel, type]))
            else { throw LinkCryptoError.sealFailed }
            return box.ciphertext + box.tag
        }
    }

    struct Opener {
        private let key: SymmetricKey
        private var counter: UInt64 = 0

        init(key: SymmetricKey) { self.key = key }

        mutating func open(_ payload: Data, channel: UInt8, type: UInt8) throws -> Data {
            guard payload.count > 16 else { throw LinkCryptoError.openFailed }
            let nonce = LinkCrypto.nonce(counter: counter)
            let ciphertext = payload.prefix(payload.count - 16)
            let tag = payload.suffix(16)
            guard let box = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce),
                                                   ciphertext: ciphertext, tag: tag),
                  let plaintext = try? AES.GCM.open(box, using: key, authenticating: Data([channel, type]))
            else { throw LinkCryptoError.openFailed }
            counter += 1
            return plaintext
        }
    }

    private static func nonce(counter: UInt64) -> Data {
        var nonce = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { nonce.append(contentsOf: $0) }
        return nonce
    }
}
