//
//  ScrcpyProtocol.swift
//  ConduitMedia
//
//  Protocol types for scrcpy v4.1
//
//  All layouts verified against the pinned v4.1 source:
//    - Streamer.java: packet framing, session packets, frame headers
//    - DesktopConnection.java: dummy byte, device name (64 bytes)
//    - demuxer.c: codec IDs, header parsing, flag masks
//

import Foundation

// MARK: - Parser State

/// State machine for the incremental scrcpy protocol parser.
///
/// Transitions:
///   waitingForDummy → readingDeviceName → readingCodecId
///   → readingPacketHeader ⇄ readingFramePayload
///
/// Session packets (12 bytes, no payload) stay in readingPacketHeader.
/// Frame packets transition to readingFramePayload, then back.
enum ScrcpyParserState: CustomStringConvertible {
    case waitingForDummy
    case readingDeviceName
    case readingCodecId
    case readingPacketHeader
    case readingFramePayload(expectedSize: Int)
    /// Terminal state — the stream is desynchronized (corruption).
    /// The parser stops processing and must be `reset()` to recover.
    case error

    var description: String {
        switch self {
        case .waitingForDummy:          "WAITING_FOR_DUMMY"
        case .readingDeviceName:        "READING_DEVICE_NAME"
        case .readingCodecId:           "READING_CODEC_ID"
        case .readingPacketHeader:      "READING_PACKET_HEADER"
        case .readingFramePayload(let n): "READING_FRAME_PAYLOAD(\(n) bytes)"
        case .error:                    "ERROR"
        }
    }
}

// MARK: - Codec

/// Video codec identifiers from scrcpy v4.1.
/// Values are the ASCII encoding of the codec name, read as uint32 big-endian.
/// Source: demuxer.c SC_CODEC_ID_* constants.
enum ScrcpyCodec: UInt32, CustomStringConvertible {
    case h264 = 0x68323634  // "h264"
    case h265 = 0x68323635  // "h265"
    case av1  = 0x00617631  // "\0av1"
    case vp8  = 0x00767038  // "\0vp8"
    case vp9  = 0x00767039  // "\0vp9"

    var description: String {
        switch self {
        case .h264: "H.264"
        case .h265: "H.265"
        case .av1:  "AV1"
        case .vp8:  "VP8"
        case .vp9:  "VP9"
        }
    }
}

// MARK: - Device Metadata

/// Device name sent by the server after the dummy byte.
/// 64-byte null-terminated UTF-8 string, zero-padded.
/// Source: DesktopConnection.java DEVICE_NAME_FIELD_LENGTH = 64.
struct ScrcpyDeviceInfo: CustomStringConvertible {
    static let fieldLength = 64

    let deviceName: String

    var description: String { deviceName }
}

// MARK: - Video Session

/// Sent as a 12-byte session packet before the first frame
/// and whenever the video dimensions change (e.g. rotation).
///
/// Layout (from Streamer.java writeSessionMeta):
///   bytes 0–3:  uint32_be flags  (bit 31 = session flag, bit 0 = client_resized)
///   bytes 4–7:  uint32_be width
///   bytes 8–11: uint32_be height
struct ScrcpyVideoSession: CustomStringConvertible {
    let width: Int
    let height: Int
    let isClientResize: Bool

    var description: String { "\(width)×\(height)\(isClientResize ? " (client resize)" : "")" }
}

// MARK: - Frame Header

/// Metadata for a single video frame, parsed from the 12-byte frame header.
///
/// Layout (from Streamer.java writeFrameMeta / demuxer.c):
///   bytes 0–7:  int64_be  pts_and_flags
///     bit 63 = 0 (not a session packet)
///     bit 62 = CONFIG flag (codec config data, e.g. SPS/PPS)
///     bit 61 = KEY_FRAME flag
///     bits 0–60 = PTS in microseconds
///   bytes 8–11: uint32_be payload_size
struct ScrcpyFrameHeader {
    let pts: Int64
    let isConfig: Bool
    let isKeyFrame: Bool
    let payloadSize: Int
}

/// A complete parsed video frame: header metadata + raw codec payload.
struct ScrcpyVideoFrame {
    let header: ScrcpyFrameHeader
    let data: Data
}

// MARK: - Parser Events

/// Events emitted by ScrcpyVideoParser as it processes the byte stream.
enum ScrcpyParserEvent {
    case dummyByteReceived
    case deviceInfoReceived(ScrcpyDeviceInfo)
    case codecDetected(ScrcpyCodec)
    case videoSessionReceived(ScrcpyVideoSession)
    case videoFrameReceived(ScrcpyVideoFrame)
    case parserError(ScrcpyParserError)
}

// MARK: - Parser Errors

/// Errors that can occur during protocol parsing.
/// The parser logs these and attempts to continue where possible.
enum ScrcpyParserError: Error, CustomStringConvertible {
    case unexpectedDummyByte(UInt8)
    case unsupportedCodec(UInt32)
    case impossiblePayloadSize(Int)

    var description: String {
        switch self {
        case .unexpectedDummyByte(let b):
            "Unexpected dummy byte: 0x\(String(format: "%02x", b))"
        case .unsupportedCodec(let id):
            "Unsupported codec ID: 0x\(String(format: "%08x", id))"
        case .impossiblePayloadSize(let s):
            "Impossible payload size: \(s) bytes"
        }
    }
}

// MARK: - Protocol Constants

/// Wire protocol constants from scrcpy v4.1.
enum ScrcpyConstants {
    /// Header size for both session and frame packets.
    /// Source: demuxer.c SC_PACKET_HEADER_SIZE = 12
    static let packetHeaderSize = 12

    /// Bit 63 of the first 8 bytes: session packet indicator.
    /// Source: Streamer.java PACKET_FLAG_SESSION = 1L << 63
    static let packetFlagSession:  UInt64 = 1 << 63

    /// Bit 62: codec configuration data (SPS/PPS for H.264).
    /// Source: demuxer.c SC_PACKET_FLAG_CONFIG = UINT64_C(1) << 62
    static let packetFlagConfig:   UInt64 = 1 << 62

    /// Bit 61: key frame indicator.
    /// Source: demuxer.c SC_PACKET_FLAG_KEY_FRAME = UINT64_C(1) << 61
    static let packetFlagKeyFrame: UInt64 = 1 << 61

    /// Mask for extracting PTS from the pts_and_flags field.
    /// Source: demuxer.c SC_PACKET_PTS_MASK = SC_PACKET_FLAG_KEY_FRAME - 1
    static let ptsMask: UInt64 = packetFlagKeyFrame - 1

    /// Maximum sane payload size (10 MB). Anything larger is treated as corruption.
    static let maxPayloadSize = 10 * 1024 * 1024
}
