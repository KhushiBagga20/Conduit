//
//  Frame.swift
//  ConduitProtocol
//
//  Conduit Link framing. Spec: Shared/Protocol/README.md §2.
//
//      ┌─────────┬─────────┬───────────────────┬─────────────────┐
//      │ channel │  type   │   length (u32 BE) │ payload         │
//      └─────────┴─────────┴───────────────────┴─────────────────┘
//
//  The header and the channel layouts come from the trackpad prototype that
//  preceded Conduit, measured on real hardware. There is no magic number and
//  no resynchronisation: TCP neither drops nor reorders bytes, so an unknown
//  channel or type can only mean a bug, and guessing past it would turn
//  garbage into input events.
//

import Foundation

public enum LinkChannel: UInt8, Sendable, CaseIterable {
    case control = 0
    case input = 1
    case sensor = 2
    case haptic = 3
    case media = 4
    case file = 5

    /// Largest payload accepted on this channel.
    public var maxPayloadSize: Int {
        self == .control ? 1 << 20 : 4 << 20
    }

    /// Frame types defined on this channel in protocol v1. Reserved channels
    /// define none yet, so any frame on them is rejected.
    public var knownTypes: Set<UInt8> {
        switch self {
        case .control: return [ControlType.handshake.rawValue, ControlType.envelope.rawValue]
        case .input:   return Set(InputType.allCases.map(\.rawValue))
        case .haptic:  return [HapticType.vibrate.rawValue]
        case .sensor, .media, .file: return []
        }
    }
}

public enum ControlType: UInt8, Sendable {
    /// Plaintext; only before the session is established.
    case handshake = 0
    /// A sealed Envelope; only after.
    case envelope = 1
}

public struct Frame: Sendable, Equatable {
    public static let headerSize = 6

    public let channel: LinkChannel
    public let type: UInt8
    public let payload: Data

    public init(channel: LinkChannel, type: UInt8, payload: Data = Data()) {
        self.channel = channel
        self.type = type
        self.payload = payload
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(channel.rawValue)
        out.append(type)
        let length = UInt32(payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

public enum FrameError: Error, Sendable, Equatable {
    case unknownChannel(UInt8)
    case unknownType(channel: LinkChannel, type: UInt8)
    case tooLarge(channel: LinkChannel, length: Int)
}

/// Incremental frame decoder. TCP delivers arbitrary chunks, so bytes are
/// buffered and every complete frame is returned; the remainder waits for
/// the next call. After an error the decoder refuses further input — the
/// stream position can no longer be trusted.
public struct FrameDecoder: Sendable {

    private var buffer = Data()
    public private(set) var failure: FrameError?

    public init() {}

    public mutating func receive(_ data: Data) throws -> [Frame] {
        if let failure { throw failure }
        buffer.append(data)

        var frames: [Frame] = []
        while buffer.count >= Frame.headerSize {
            let base = buffer.startIndex
            let rawChannel = buffer[base]
            let type = buffer[base + 1]
            let length = Int(buffer[base + 2]) << 24 | Int(buffer[base + 3]) << 16
                       | Int(buffer[base + 4]) << 8 | Int(buffer[base + 5])

            guard let channel = LinkChannel(rawValue: rawChannel) else {
                return try fail(.unknownChannel(rawChannel))
            }
            guard channel.knownTypes.contains(type) else {
                return try fail(.unknownType(channel: channel, type: type))
            }
            guard length <= channel.maxPayloadSize else {
                return try fail(.tooLarge(channel: channel, length: length))
            }
            guard buffer.count >= Frame.headerSize + length else { break }

            let start = base + Frame.headerSize
            frames.append(Frame(channel: channel, type: type, payload: Data(buffer[start ..< start + length])))
            buffer.removeSubrange(base ..< start + length)
        }
        return frames
    }

    private mutating func fail(_ error: FrameError) throws -> [Frame] {
        failure = error
        buffer.removeAll()
        throw error
    }
}
