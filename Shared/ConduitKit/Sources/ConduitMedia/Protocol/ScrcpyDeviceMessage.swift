//
//  ScrcpyDeviceMessage.swift
//  ConduitMedia
//
//  Device→client messages on the control socket.
//
//  The control channel is bidirectional; this is the read side. The server pushes a CLIPBOARD message whenever
//  the device clipboard changes (clipboard_autosync, on by default), which
//  is what makes copy-on-phone → paste-on-Mac work.
//
//  Layouts verified against pinned v4.1 source:
//    - app/src/device_msg.c / device_msg.h
//
//  Same TCP reality as the video stream: messages split across reads and
//  arrive several-per-read, so this parser is incremental and keeps
//  leftover bytes for the next call.
//

import Foundation

// MARK: - Message Types

/// Device message type IDs.
/// Source: device_msg.h `enum sc_device_msg_type`.
enum ScrcpyDeviceMessageType: UInt8 {
    case clipboard    = 0
    case ackClipboard = 1
    case uhidOutput   = 2
}

// MARK: - Messages

/// A message sent by the device to the client.
enum ScrcpyDeviceMessage {
    /// The device clipboard changed, or answered a GET_CLIPBOARD.
    case clipboard(String)

    /// The device acknowledged a SET_CLIPBOARD carrying this sequence.
    /// Conduit sends sequence 0 (no ack wanted), so this is not expected today.
    case acknowledgeClipboard(sequence: UInt64)

    /// Output from a UHID device. Unused — parsed only so an unexpected
    /// one cannot desynchronise the stream.
    case uhidOutput(id: UInt16, data: Data)
}

// MARK: - Parser

/// Incremental parser for the device→client message stream.
///
/// Call `receive(_:)` with each chunk read from the control socket.
/// `onMessage` fires for each complete message; partial data is retained.
final class ScrcpyDeviceMessageParser {

    /// Guard against a corrupt length turning into a huge allocation.
    /// Upstream declares no explicit cap, so this mirrors the video
    /// parser's defensive limit rather than trusting the wire.
    static let maxPayloadSize = 1 * 1024 * 1024

    private var buffer = Data()
    private let onMessage: (ScrcpyDeviceMessage) -> Void

    /// Set when a malformed message is seen. The stream position can no
    /// longer be trusted, so parsing stops until reset().
    private(set) var isDesynchronised = false

    init(onMessage: @escaping (ScrcpyDeviceMessage) -> Void) {
        self.onMessage = onMessage
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        isDesynchronised = false
    }

    func receive(_ data: Data) {
        guard !isDesynchronised else { return }
        buffer.append(data)
        drain()
    }

    // MARK: - Drain

    private func drain() {
        while !isDesynchronised {
            guard let consumed = parseOneMessage() else { return }
            guard consumed > 0 else { return }
        }
    }

    /// Try to parse a single message from the head of the buffer.
    /// Returns the byte count consumed, or nil when more data is needed.
    private func parseOneMessage() -> Int? {
        guard let typeByte = buffer.first else { return nil }

        guard let type = ScrcpyDeviceMessageType(rawValue: typeByte) else {
            // An unknown type means the stream is no longer aligned; there
            // is no length field to skip past, so recovery is impossible.
            Log.control.error("unknown type \(typeByte) — desynchronised")
            isDesynchronised = true
            buffer.removeAll()
            return nil
        }

        switch type {
        case .clipboard:
            // [0] type [1..4] utf8_length [5…] utf8
            guard buffer.count >= 5 else { return nil }
            let length = Int(readUInt32BE(at: 1))

            guard length >= 0, length <= Self.maxPayloadSize else {
                Log.control.error("implausible clipboard length \(length)")
                isDesynchronised = true
                buffer.removeAll()
                return nil
            }

            let total = 5 + length
            guard buffer.count >= total else { return nil }

            let textData = buffer.subdata(in: (buffer.startIndex + 5) ..< (buffer.startIndex + total))
            consume(total)

            let text = String(data: textData, encoding: .utf8) ?? ""
            onMessage(.clipboard(text))
            return total

        case .ackClipboard:
            // [0] type [1..8] sequence
            guard buffer.count >= 9 else { return nil }
            let sequence = readUInt64BE(at: 1)
            consume(9)
            onMessage(.acknowledgeClipboard(sequence: sequence))
            return 9

        case .uhidOutput:
            // [0] type [1..2] id [3..4] size [5…] data
            guard buffer.count >= 5 else { return nil }
            let id = readUInt16BE(at: 1)
            let size = Int(readUInt16BE(at: 3))
            let total = 5 + size
            guard buffer.count >= total else { return nil }

            let payload = buffer.subdata(in: (buffer.startIndex + 5) ..< (buffer.startIndex + total))
            consume(total)
            onMessage(.uhidOutput(id: id, data: payload))
            return total
        }
    }

    private func consume(_ count: Int) {
        buffer.removeFirst(count)
    }

    // MARK: - Big-Endian Readers

    private func readUInt16BE(at offset: Int) -> UInt16 {
        let i = buffer.startIndex + offset
        return (UInt16(buffer[i]) << 8) | UInt16(buffer[i + 1])
    }

    private func readUInt32BE(at offset: Int) -> UInt32 {
        let i = buffer.startIndex + offset
        return (UInt32(buffer[i])     << 24)
             | (UInt32(buffer[i + 1]) << 16)
             | (UInt32(buffer[i + 2]) << 8)
             |  UInt32(buffer[i + 3])
    }

    private func readUInt64BE(at offset: Int) -> UInt64 {
        let i = buffer.startIndex + offset
        var value: UInt64 = 0
        for byte in 0..<8 {
            value = (value << 8) | UInt64(buffer[i + byte])
        }
        return value
    }
}
