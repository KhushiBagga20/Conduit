//
//  ScrcpyVideoParser.swift
//  ConduitMedia
//
//  Incremental streaming parser for the scrcpy v4.1 video protocol.
//
//  CRITICAL DESIGN: TCP does not preserve message boundaries.
//  This parser maintains an internal byte buffer and correctly handles:
//    - partial headers
//    - partial payloads
//    - multiple packets in one read
//    - packets split across many reads
//    - arbitrary read boundaries
//
//  The parser consumes as many complete structures as possible from
//  the buffer and retains incomplete data for the next call.
//

import Foundation

/// Incremental streaming parser for the scrcpy v4.1 wire protocol.
///
/// Call `receive(_:)` with each chunk of TCP data. The parser will
/// invoke the `onEvent` callback for each complete protocol structure
/// it extracts from the stream. Leftover bytes are retained internally.
///
/// Call `reset()` on disconnect to prepare for a new connection.
final class ScrcpyVideoParser {

    // MARK: - State

    private(set) var parserState: ScrcpyParserState = .waitingForDummy
    private var buffer = Data()

    /// Pending frame header while awaiting payload bytes.
    private var pendingFrameHeader: ScrcpyFrameHeader?

    // MARK: - Logging

    private(set) var frameCount: Int = 0
    private var lastLoggedFrameCount: Int = 0
    private var lastLogTime: TimeInterval = 0
    /// Log at most once per this interval (seconds).
    private let logInterval: TimeInterval = 2.0

    // MARK: - Event Callback

    private let onEvent: (ScrcpyParserEvent) -> Void

    // MARK: - Init

    /// - Parameter onEvent: Called synchronously on the caller's thread
    ///   for each parsed protocol event.
    init(onEvent: @escaping (ScrcpyParserEvent) -> Void) {
        self.onEvent = onEvent
    }

    // MARK: - Public API

    /// Feed raw TCP bytes into the parser.
    /// May emit zero or more events via `onEvent`.
    func receive(_ data: Data) {
        if case .error = parserState {
            // Parser is in error state — discard data until reset().
            return
        }
        buffer.append(data)
        drain()
    }

    /// Reset parser state for a new connection.
    func reset() {
        buffer.removeAll(keepingCapacity: true)
        parserState = .waitingForDummy
        pendingFrameHeader = nil
        frameCount = 0
        lastLoggedFrameCount = 0
        lastLogTime = 0
    }

    // MARK: - Buffer Drain Loop

    /// Attempt to consume as many complete structures as possible.
    private func drain() {
        // Loop until we can't make progress (not enough bytes).
        while true {
            switch parserState {

            case .waitingForDummy:
                guard buffer.count >= 1 else { return }
                let byte = consumeBytes(1)[0]
                if byte != 0 {
                    onEvent(.parserError(.unexpectedDummyByte(byte)))
                    // Continue anyway — the byte has been consumed.
                }
                onEvent(.dummyByteReceived)
                parserState = .readingDeviceName

            case .readingDeviceName:
                guard buffer.count >= ScrcpyDeviceInfo.fieldLength else { return }
                let nameData = consumeBytes(ScrcpyDeviceInfo.fieldLength)
                let name = parseNullTerminatedString(nameData)
                let info = ScrcpyDeviceInfo(deviceName: name)
                onEvent(.deviceInfoReceived(info))
                parserState = .readingCodecId

            case .readingCodecId:
                guard buffer.count >= 4 else { return }
                let data = consumeBytes(4)
                let rawId = readUInt32BE(data, at: 0)
                if let codec = ScrcpyCodec(rawValue: rawId) {
                    onEvent(.codecDetected(codec))
                } else {
                    onEvent(.parserError(.unsupportedCodec(rawId)))
                }
                parserState = .readingPacketHeader

            case .readingPacketHeader:
                guard buffer.count >= ScrcpyConstants.packetHeaderSize else { return }
                let header = consumeBytes(ScrcpyConstants.packetHeaderSize)
                parsePacketHeader(header)

            case .readingFramePayload(let expectedSize):
                guard buffer.count >= expectedSize else { return }
                let payload = consumeBytes(expectedSize)
                guard let fh = pendingFrameHeader else { return }
                let frame = ScrcpyVideoFrame(header: fh, data: payload)
                pendingFrameHeader = nil
                frameCount += 1
                onEvent(.videoFrameReceived(frame))
                logFrameIfNeeded(frame)
                parserState = .readingPacketHeader

            case .error:
                // Terminal state — stop processing.
                return
            }
        }
    }

    // MARK: - Packet Header Parsing

    /// Parse a 12-byte packet header. Determines whether it is a
    /// session packet (no payload) or a frame packet (has payload).
    private func parsePacketHeader(_ data: Data) {
        // Read the first 8 bytes as uint64 to check the session flag (bit 63).
        let first8 = readUInt64BE(data, at: 0)
        let isSession = (first8 & ScrcpyConstants.packetFlagSession) != 0

        if isSession {
            // Session packet: [4-byte flags] [4-byte width] [4-byte height]
            // No payload follows.
            let flags  = readUInt32BE(data, at: 0)
            let width  = readUInt32BE(data, at: 4)
            let height = readUInt32BE(data, at: 8)
            let isClientResize = (flags & 1) != 0
            let session = ScrcpyVideoSession(
                width: Int(width),
                height: Int(height),
                isClientResize: isClientResize
            )
            onEvent(.videoSessionReceived(session))
            // Stay in .readingPacketHeader — next 12 bytes are the next packet.
        } else {
            // Frame packet: [8-byte pts_and_flags] [4-byte payload_size]
            let isConfig   = (first8 & ScrcpyConstants.packetFlagConfig) != 0
            let isKeyFrame = (first8 & ScrcpyConstants.packetFlagKeyFrame) != 0
            let pts        = Int64(bitPattern: first8 & ScrcpyConstants.ptsMask)

            let payloadSize = Int(readUInt32BE(data, at: 8))

            // Sanity check
            if payloadSize < 0 || payloadSize > ScrcpyConstants.maxPayloadSize {
                onEvent(.parserError(.impossiblePayloadSize(payloadSize)))
                // Stream is desynchronized — further parsing would cascade errors.
                // Clear the buffer and enter terminal error state.
                buffer.removeAll()
                pendingFrameHeader = nil
                parserState = .error
                return
            }

            let header = ScrcpyFrameHeader(
                pts: pts,
                isConfig: isConfig,
                isKeyFrame: isKeyFrame,
                payloadSize: payloadSize
            )

            if payloadSize == 0 {
                // Degenerate case: frame with empty payload.
                let frame = ScrcpyVideoFrame(header: header, data: Data())
                frameCount += 1
                onEvent(.videoFrameReceived(frame))
                parserState = .readingPacketHeader
            } else {
                pendingFrameHeader = header
                parserState = .readingFramePayload(expectedSize: payloadSize)
            }
        }
    }

    // MARK: - Rate-Limited Frame Logging

    private func logFrameIfNeeded(_ frame: ScrcpyVideoFrame) {
        // Always log config (SPS/PPS) and key frames
        if frame.header.isConfig || frame.header.isKeyFrame {
            logFrame(frame)
            return
        }

        // Rate-limit P-frame logging
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLogTime >= logInterval {
            logFrame(frame)
            lastLogTime = now
            lastLoggedFrameCount = frameCount
        }
    }

    private func logFrame(_ frame: ScrcpyVideoFrame) {
        let kind: String
        if frame.header.isConfig {
            kind = "CONFIG"
        } else if frame.header.isKeyFrame {
            kind = "KEY"
        } else {
            kind = "P"
        }
        Log.wire.debug("Frame #\(frameCount) | \(kind) | PTS: \(frame.header.pts) µs | Size: \(frame.data.count) bytes")
    }

    // MARK: - Buffer Helpers

    /// Consume and return the first `count` bytes from the buffer.
    /// Precondition: buffer.count >= count.
    private func consumeBytes(_ count: Int) -> Data {
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    // MARK: - Big-Endian Readers

    /// Read a big-endian uint32 from `data` at byte offset `offset`.
    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i])     << 24)
             | (UInt32(data[i + 1]) << 16)
             | (UInt32(data[i + 2]) << 8)
             |  UInt32(data[i + 3])
    }

    /// Read a big-endian uint64 from `data` at byte offset `offset`.
    private func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let i = data.startIndex + offset
        return (UInt64(data[i])     << 56)
             | (UInt64(data[i + 1]) << 48)
             | (UInt64(data[i + 2]) << 40)
             | (UInt64(data[i + 3]) << 32)
             | (UInt64(data[i + 4]) << 24)
             | (UInt64(data[i + 5]) << 16)
             | (UInt64(data[i + 6]) << 8)
             |  UInt64(data[i + 7])
    }

    // MARK: - String Helpers

    /// Extract a null-terminated UTF-8 string from fixed-length data.
    private func parseNullTerminatedString(_ data: Data) -> String {
        // Find the first null byte.
        if let nullIndex = data.firstIndex(of: 0) {
            let slice = data[data.startIndex ..< nullIndex]
            return String(data: Data(slice), encoding: .utf8) ?? "Unknown"
        }
        // No null found — use entire data.
        return String(data: data, encoding: .utf8) ?? "Unknown"
    }
}
