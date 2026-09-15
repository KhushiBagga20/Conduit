//
//  Envelope.swift
//  ConduitProtocol
//
//  The JSON message carried on channel 0 after the handshake: a command, a
//  response or an event. Spec: Shared/Protocol/README.md §3.
//
//  Decoding enforces every field rule in the spec, so a malformed envelope
//  is rejected at the edge instead of reaching feature code half-formed.
//

import Foundation

public enum ProtocolVersion {
    /// The version this build speaks.
    public static let current = 1
    /// The oldest version this build accepts.
    public static let minimum = 1
}

public struct Envelope: Sendable, Equatable {

    public enum Kind: Sendable, Equatable {
        case command(requestID: String, action: ActionName)
        case response(requestID: String, outcome: Outcome)
        case event(name: EventName, epoch: String, seq: UInt64, timestamp: Int64?)
    }

    public enum Outcome: Sendable, Equatable {
        case success
        case failure(ProtocolError)
    }

    public var version: Int
    public var kind: Kind
    /// Always an object when present (spec §3, `payload`).
    public var payload: [String: JSONValue]?

    public init(version: Int = ProtocolVersion.current, kind: Kind, payload: [String: JSONValue]? = nil) {
        self.version = version
        self.kind = kind
        self.payload = payload
    }

    // MARK: Constructors

    public static func command(_ action: ActionName, payload: [String: JSONValue]? = nil,
                               requestID: String = UUID().uuidString) -> Envelope {
        Envelope(kind: .command(requestID: requestID, action: action), payload: payload)
    }

    public static func success(to requestID: String, payload: [String: JSONValue]? = nil) -> Envelope {
        Envelope(kind: .response(requestID: requestID, outcome: .success), payload: payload)
    }

    public static func failure(to requestID: String, _ error: ProtocolError) -> Envelope {
        Envelope(kind: .response(requestID: requestID, outcome: .failure(error)))
    }

    public static func event(_ name: EventName, epoch: String, seq: UInt64,
                             timestamp: Int64? = nil, payload: [String: JSONValue]? = nil) -> Envelope {
        Envelope(kind: .event(name: name, epoch: epoch, seq: seq, timestamp: timestamp), payload: payload)
    }

    // MARK: Wire

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }
}

extension Envelope: Codable {

    private enum CodingKeys: String, CodingKey {
        case v, type, requestID, action, event, status, error, epoch, seq, timestamp, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .v)

        if c.contains(.payload) {
            guard case .object(let fields) = try c.decode(JSONValue.self, forKey: .payload) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .payload, in: c, debugDescription: "payload must be a JSON object")
            }
            payload = fields
        } else {
            payload = nil
        }

        switch try c.decode(String.self, forKey: .type) {
        case "command":
            kind = .command(
                requestID: try c.decode(String.self, forKey: .requestID),
                action: ActionName(try c.decode(String.self, forKey: .action)))

        case "response":
            let requestID = try c.decode(String.self, forKey: .requestID)
            switch try c.decode(String.self, forKey: .status) {
            case "success":
                kind = .response(requestID: requestID, outcome: .success)
            case "failure":
                kind = .response(requestID: requestID,
                                 outcome: .failure(try c.decode(ProtocolError.self, forKey: .error)))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status, in: c, debugDescription: "status must be success or failure")
            }

        case "event":
            let seq = try c.decode(UInt64.self, forKey: .seq)
            guard seq >= 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .seq, in: c, debugDescription: "seq starts at 1")
            }
            kind = .event(
                name: EventName(try c.decode(String.self, forKey: .event)),
                epoch: try c.decode(String.self, forKey: .epoch),
                seq: seq,
                timestamp: try c.decodeIfPresent(Int64.self, forKey: .timestamp))

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "type must be command, response or event")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .v)

        switch kind {
        case let .command(requestID, action):
            try c.encode("command", forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(action.rawValue, forKey: .action)

        case let .response(requestID, outcome):
            try c.encode("response", forKey: .type)
            try c.encode(requestID, forKey: .requestID)
            switch outcome {
            case .success:
                try c.encode("success", forKey: .status)
            case .failure(let error):
                try c.encode("failure", forKey: .status)
                try c.encode(error, forKey: .error)
            }

        case let .event(name, epoch, seq, timestamp):
            try c.encode("event", forKey: .type)
            try c.encode(name.rawValue, forKey: .event)
            try c.encode(epoch, forKey: .epoch)
            try c.encode(seq, forKey: .seq)
            try c.encodeIfPresent(timestamp, forKey: .timestamp)
        }

        if let payload {
            try c.encode(JSONValue.object(payload), forKey: .payload)
        }
    }
}
