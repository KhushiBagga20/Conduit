//
//  Handshake.swift
//  ConduitProtocol
//
//  The handshake messages of Conduit Link v1 — Shared/Protocol/README.md §5.
//  They travel as `control/handshake` frames: JSON objects, plaintext for the
//  two hellos and sealed from `auth` onwards.
//
//  Every field the spec defines is here, and nothing else. A message is
//  hashed into the transcript exactly as it went on the wire, so these are
//  never re-encoded before hashing.
//

import Foundation

public nonisolated enum HandshakeStep: String, Codable, Sendable {
    case hello
    case auth
    case ready
    case error
    case pairNonce = "pair.nonce"
    case pairReveal = "pair.reveal"
    case pairConfirm = "pair.confirm"
    case pairReject = "pair.reject"
}

/// What the phone is asking for.
public nonisolated enum HandshakeIntent: String, Codable, Sendable {
    case connect
    case pair
}

/// What the Mac answered: prove an identity it already trusts, or pair.
public nonisolated enum HandshakeMode: String, Codable, Sendable {
    case authenticate
    case pair
}

public nonisolated struct LinkSessionInfo: Codable, Sendable, Equatable {
    public var epoch: String
    public var heartbeatSeconds: Int

    public init(epoch: String, heartbeatSeconds: Int) {
        self.epoch = epoch
        self.heartbeatSeconds = heartbeatSeconds
    }
}

/// One handshake message. Fields not used by a step are absent.
public nonisolated struct HandshakeMessage: Codable, Sendable, Equatable {

    public static let messageType = "handshake"

    public var type: String
    public var step: HandshakeStep

    /// Hello, both directions.
    public var versions: [Int]?
    public var device: DeviceInfo?
    /// Base64, X9.63 uncompressed point.
    public var identityKey: String?
    public var ephemeralKey: String?
    public var intent: HandshakeIntent?

    /// Hello, Mac only.
    public var version: Int?
    public var mode: HandshakeMode?
    /// Base64 HMAC-SHA256 over the two ephemeral keys, keyed with the Mac's
    /// secret nonce — so the Mac commits to it before seeing the phone's.
    public var commitment: String?

    /// `pair.nonce` carries the phone's nonce, `pair.reveal` the Mac's.
    public var nonce: String?
    /// Base64 DER ECDSA signature: `auth` and `pair.confirm`.
    public var signature: String?

    /// Ready, Mac only.
    public var session: LinkSessionInfo?
    /// Error, either direction.
    public var error: ProtocolError?

    public init(step: HandshakeStep) {
        type = Self.messageType
        self.step = step
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> HandshakeMessage {
        let message = try JSONDecoder().decode(HandshakeMessage.self, from: data)
        guard message.type == messageType else {
            throw ProtocolError(.invalidRequest, "Not a handshake message.")
        }
        return message
    }
}
