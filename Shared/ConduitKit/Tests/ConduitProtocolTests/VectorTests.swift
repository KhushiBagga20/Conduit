//
//  VectorTests.swift
//  ConduitProtocolTests
//
//  Runs the language-neutral vectors in Shared/Protocol/vectors. Android's
//  core module runs the same files; that is what keeps two implementations
//  one protocol.
//

import Foundation
import Testing
@testable import ConduitProtocol

private let vectorsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // ConduitProtocolTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // ConduitKit
    .deletingLastPathComponent()   // Shared
    .appendingPathComponent("Protocol/vectors")

private func loadVectors(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: vectorsDirectory.appendingPathComponent(name))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Structural JSON equality that, unlike NSNumber comparison, keeps booleans
/// and numbers distinct — `true` must never compare equal to `1`.
private func jsonEqual(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case let (x as [String: Any], y as [String: Any]):
        return x.count == y.count && x.allSatisfy { key, value in y[key].map { jsonEqual(value, $0) } ?? false }
    case let (x as [Any], y as [Any]):
        return x.count == y.count && zip(x, y).allSatisfy(jsonEqual)
    case let (x as NSNumber, y as NSNumber):
        let xBool = CFGetTypeID(x) == CFBooleanGetTypeID()
        let yBool = CFGetTypeID(y) == CFBooleanGetTypeID()
        return xBool == yBool && x == y
    case let (x as String, y as String):
        return x == y
    case (is NSNull, is NSNull):
        return true
    default:
        return false
    }
}

@Suite("Envelope vectors")
struct EnvelopeVectorTests {

    @Test("valid envelopes decode and re-encode to the same JSON value")
    func validEnvelopes() throws {
        let vectors = try loadVectors("envelopes.json")
        let valid = try #require(vectors["valid"] as? [[String: Any]])
        #expect(!valid.isEmpty)

        for vector in valid {
            let name = vector["name"] as? String ?? "?"
            let input = vector["input"] ?? vector["json"]!
            let expected = vector["json"]!

            let inputData = try JSONSerialization.data(withJSONObject: input)
            let envelope = try Envelope.decode(inputData)
            let reencoded = try JSONSerialization.jsonObject(with: envelope.encoded())

            #expect(jsonEqual(reencoded, expected), "vector: \(name)")
        }
    }

    @Test("invalid envelopes are rejected")
    func invalidEnvelopes() throws {
        let vectors = try loadVectors("envelopes.json")
        let invalid = try #require(vectors["invalid"] as? [[String: Any]])
        #expect(!invalid.isEmpty)

        for vector in invalid {
            let name = vector["name"] as? String ?? "?"
            let data = try JSONSerialization.data(withJSONObject: vector["json"]!)
            #expect(throws: (any Error).self, "vector: \(name)") {
                try Envelope.decode(data)
            }
        }
    }
}

@Suite("Frame vectors")
struct FrameVectorTests {

    @Test("frames encode to the expected bytes and decode back")
    func frames() throws {
        let vectors = try loadVectors("frames.json")
        let frames = try #require(vectors["frames"] as? [[String: Any]])
        #expect(!frames.isEmpty)

        for vector in frames {
            let name = vector["name"] as? String ?? "?"
            let channel = try #require(LinkChannel(rawValue: UInt8(vector["channel"] as! Int)))
            let type = UInt8(vector["type"] as! Int)
            let payload = try #require(Data(hex: vector["payloadHex"] as! String))
            let bytes = try #require(Data(hex: vector["frameHex"] as! String))

            let frame = Frame(channel: channel, type: type, payload: payload)
            #expect(frame.encoded() == bytes, "encode: \(name)")

            var decoder = FrameDecoder()
            #expect(try decoder.receive(bytes) == [frame], "decode: \(name)")
        }
    }

    @Test("frames split at every byte boundary still decode")
    func byteAtATime() throws {
        let vectors = try loadVectors("frames.json")
        let frames = try #require(vectors["frames"] as? [[String: Any]])
        let stream = frames.compactMap { Data(hex: $0["frameHex"] as! String) }.reduce(Data(), +)

        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        for byte in stream {
            decoded += try decoder.receive(Data([byte]))
        }
        #expect(decoded.count == frames.count)
        #expect(decoded.map { $0.encoded() }.reduce(Data(), +) == stream)
    }

    @Test("rejected frames fail and poison the decoder")
    func rejected() throws {
        let vectors = try loadVectors("frames.json")
        let rejected = try #require(vectors["rejected"] as? [[String: Any]])

        for vector in rejected {
            let name = vector["name"] as? String ?? "?"
            let bytes = try #require(Data(hex: vector["hex"] as! String))
            let reason = vector["reason"] as! String

            var decoder = FrameDecoder()
            do {
                _ = try decoder.receive(bytes)
                Issue.record("expected rejection: \(name)")
            } catch let error as FrameError {
                switch (error, reason) {
                case (.unknownChannel, "unknown_channel"), (.unknownType, "unknown_type"), (.tooLarge, "too_large"):
                    break
                default:
                    Issue.record("wrong error \(error) for \(name)")
                }
            }
            #expect(throws: FrameError.self) { try decoder.receive(Data([0])) }
        }
    }
}

@Suite("Binary messages")
struct BinaryMessageTests {

    @Test("input events round-trip through frames")
    func inputRoundTrip() {
        let events: [InputEvent] = [
            .move(dx: -3, dy: 12), .move(dx: .min, dy: .max),
            .button(.left, down: true), .button(.middle, down: false),
            .scroll(dx: 0, dy: -20), .key(.volumeDown, down: false),
        ]
        for event in events {
            #expect(InputEvent(frame: event.frame) == event)
        }
    }

    @Test("input frames match the vector bytes")
    func inputBytes() {
        #expect(InputEvent.move(dx: -3, dy: 12).frame.encoded() == Data(hex: "010000000004fffd000c"))
        #expect(InputEvent.key(.volumeDown, down: false).frame.encoded() == Data(hex: "010300000003000100"))
        #expect(Vibration(durationMs: 30, amplitude: 160).frame.encoded() == Data(hex: "030000000003001ea0"))
    }

    @Test("truncated bodies decode to nil instead of trapping")
    func truncated() {
        #expect(InputEvent(frame: Frame(channel: .input, type: 0, payload: Data([0xff]))) == nil)
        #expect(InputEvent(frame: Frame(channel: .input, type: 1, payload: Data([9, 1]))) == nil)
        #expect(Vibration(frame: Frame(channel: .haptic, type: 0, payload: Data([0]))) == nil)
    }
}

@Suite("Names and errors")
struct NameTests {

    @Test("unknown error codes are preserved on the wire and normalised for handling")
    func unknownErrorCode() throws {
        let error = ProtocolError(ErrorCode("some_future_code"), "New failure")
        let data = try Envelope.failure(to: "r", error).encoded()
        let decoded = try Envelope.decode(data)
        guard case .response(_, .failure(let roundTripped)) = decoded.kind else {
            Issue.record("expected failure response")
            return
        }
        #expect(roundTripped.code.rawValue == "some_future_code")
        #expect(roundTripped.code.normalized == .internal)
        #expect(ErrorCode.permissionDenied.normalized == .permissionDenied)
    }

    @Test("typed payloads convert to and from JSON trees")
    func typedPayload() throws {
        let snapshot = DeviceSnapshot(
            device: DeviceInfo(id: "abc", name: "Phone", platform: .android, osVersion: "16"),
            battery: BatteryStatus(level: 140, charging: true),
            features: [FeatureID.links.rawValue: .available, FeatureID.calls.rawValue: .requiresPermission])
        let tree = try JSONValue.encoding(snapshot)
        #expect(tree["battery"]?["level"]?.intValue == 100)
        #expect(tree["features"]?["calls"]?.stringValue == "requires_permission")
        #expect(try tree.decoded(as: DeviceSnapshot.self) == snapshot)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
