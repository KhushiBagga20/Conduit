//
//  AudioConnection.swift
//  ConduitMedia
//
//  The audio socket.
//
//  scrcpy v4.1 exposes video, audio and control on one LocalServerSocket
//  and accepts them IN THAT ORDER. Adding audio therefore changes the
//  handshake the session depends on: it must connect
//  video → audio → control, and only the FIRST socket receives the dummy
//  byte and the device metadata.
//
//  The audio stream is simpler than video (demuxer.c: "no subsequent
//  header is read for audio streams"):
//
//    [4 bytes]  codec id, big-endian
//    then, repeating:
//      [12 bytes] packet header (pts_and_flags, payload size)
//      [n bytes]  payload
//
//  Layouts verified against pinned v4.1 source (demuxer.c, Streamer.java).
//

import Foundation
import Network
import Observation

/// Audio codec identifiers, plus the two sentinel values the server uses
/// to report that audio will not be arriving.
/// Source: demuxer.c SC_CODEC_ID_* and its codec-id error handling.
enum ScrcpyAudioCodec: UInt32 {
    case opus = 0x6f707573  // "opus"
    case aac  = 0x00616163  // "\0aac"
    case flac = 0x666c6163  // "flac"
    case raw  = 0x00726177  // "\0raw"

    var description: String {
        switch self {
        case .opus: return "Opus"
        case .aac:  return "AAC"
        case .flac: return "FLAC"
        case .raw:  return "PCM"
        }
    }
}

/// TCP client for the scrcpy audio socket.
///
/// MUST be connected AFTER the video socket and BEFORE the control socket.
@Observable
public final class AudioConnection {

    static let defaultPort: UInt16 = 27183
    static let defaultHost = "127.0.0.1"

    // MARK: - Observable State

    public private(set) var state: SocketState = .disconnected
    public private(set) var codecName: String?
    public private(set) var errorMessage: String?

    /// True when the device told us audio will not be sent at all.
    /// Not an error — Android can refuse audio capture for policy reasons.
    public private(set) var isUnavailable = false

    // MARK: - Private

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.khushi.conduit.audio", qos: .userInitiated)
    private var generation: Int = 0

    private var player: AudioPlayer?

    /// Incremental read buffer — accessed only from `queue`.
    private var buffer = Data()

    /// False until the leading 4-byte codec id has been consumed.
    private var hasCodecID = false

    // MARK: - Callbacks

    /// Fires once the socket is ready, so the coordinator knows it is safe
    /// to connect the control socket (the server's third accept).
    var onReady: (() -> Void)?

    // MARK: - Public API

    func connect(host: String = defaultHost, port: UInt16 = defaultPort) {
        disconnect()

        generation += 1
        let gen = generation

        state = .connecting
        errorMessage = nil
        isUnavailable = false
        codecName = nil
        buffer.removeAll(keepingCapacity: true)
        hasCodecID = false

        player = AudioPlayer()

        Log.audio.info("connecting (gen \(gen))")

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.handleStateChange(newState, generation: gen)
            }
        }

        connection.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        player?.stop()
        player = nil
        buffer.removeAll(keepingCapacity: true)
        hasCodecID = false
        if state != .failed {
            state = .disconnected
        }
    }

    // MARK: - State

    private func handleStateChange(_ newState: NWConnection.State, generation gen: Int) {
        switch newState {
        case .ready:
            state = .connected
            Log.audio.notice("connected ✓ (gen \(gen))")
            player?.start()
            startReceiving(generation: gen)

            // Tell the coordinator the server has accepted this socket, so
            // the control socket can follow in the right order.
            let ready = onReady
            onReady = nil
            ready?()

        case .failed(let error):
            Log.audio.error("failed — \(error.localizedDescription)")
            connection?.cancel()
            connection = nil
            player?.stop()
            player = nil
            state = .failed
            errorMessage = error.localizedDescription
            // Still let the sequence continue: losing audio must not block
            // the control socket, or the phone becomes unusable.
            let ready = onReady
            onReady = nil
            ready?()

        case .waiting(let error):
            // Same reasoning as StreamConnection: .waiting means nothing is
            // listening, and NWConnection will not recover on its own.
            Log.audio.info("waiting — \(error.localizedDescription) (giving up on audio)")
            connection?.cancel()
            connection = nil
            player?.stop()
            player = nil
            state = .failed
            errorMessage = error.localizedDescription
            let ready = onReady
            onReady = nil
            ready?()

        case .cancelled:
            if state != .failed { state = .disconnected }

        case .preparing:
            state = .connecting

        case .setup:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Receiving

    private func startReceiving(generation gen: Int) {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, self.generation == gen else { return }

            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drain(generation: gen)
            }

            if isComplete || error != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == gen else { return }
                    Log.audio.info("stream ended")
                    self.player?.stop()
                    self.state = .disconnected
                }
                return
            }

            self.startReceiving(generation: gen)
        }
    }

    /// Consume as many complete structures as the buffer holds.
    /// Runs on `queue`.
    private func drain(generation gen: Int) {
        // 1. Leading codec id.
        if !hasCodecID {
            guard buffer.count >= 4 else { return }
            let raw = readUInt32BE(at: 0)
            buffer.removeFirst(4)
            hasCodecID = true

            // 0 and 1 are sentinels, not codecs: the device is telling us
            // audio is disabled or failed on its side.
            if raw == 0 || raw == 1 {
                let reason = raw == 0 ? "disabled on the device" : "device-side capture error"
                Log.audio.info("audio unavailable — \(reason)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == gen else { return }
                    self.isUnavailable = true
                    self.errorMessage = "Audio unavailable (\(reason))"
                }
                return
            }

            guard let codec = ScrcpyAudioCodec(rawValue: raw) else {
                Log.audio.error("unsupported audio codec 0x\(String(format: "%08x", raw))")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == gen else { return }
                    self.isUnavailable = true
                    self.errorMessage = String(format: "Unsupported audio codec 0x%08x", raw)
                }
                return
            }

            Log.audio.info("codec \(codec.description)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == gen else { return }
                self.codecName = codec.description
            }

            // Only PCM is played. Anything else would need a decoder; the
            // launcher requests raw, so this is a configuration mismatch.
            if codec != .raw {
                Log.audio.error("\(codec.description) needs a decoder Conduit does not have — silencing audio")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == gen else { return }
                    self.isUnavailable = true
                    self.errorMessage = "\(codec.description) needs a decoder; run the server with audio_codec=raw"
                }
                return
            }
        }

        // 2. Packets: 12-byte header, then payload.
        while true {
            guard buffer.count >= ScrcpyConstants.packetHeaderSize else { return }

            let payloadSize = Int(readUInt32BE(at: 8))
            guard payloadSize >= 0, payloadSize <= ScrcpyConstants.maxPayloadSize else {
                Log.audio.error("implausible payload \(payloadSize) — dropping stream")
                buffer.removeAll()
                return
            }

            let total = ScrcpyConstants.packetHeaderSize + payloadSize
            guard buffer.count >= total else { return }

            let flags = readUInt64BE(at: 0)
            let isConfig = (flags & ScrcpyConstants.packetFlagConfig) != 0

            let payload = buffer.subdata(
                in: (buffer.startIndex + ScrcpyConstants.packetHeaderSize) ..< (buffer.startIndex + total)
            )
            buffer.removeFirst(total)

            // Raw PCM has no codec config; a CONFIG packet here is metadata
            // for a compressed codec and carries no audio to play.
            if !isConfig {
                player?.enqueue(pcm: payload)
            }
        }
    }

    // MARK: - Readers

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
