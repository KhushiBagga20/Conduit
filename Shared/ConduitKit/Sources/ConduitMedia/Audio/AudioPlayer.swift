//
//  AudioPlayer.swift
//  ConduitMedia
//
//  Low-latency playback of the device audio stream.
//
//  Takes interleaved signed-16-bit PCM straight off the wire, converts it
//  to the float format AVAudioEngine wants, and schedules it on a player
//  node as it arrives.
//
//  WHY RAW PCM RATHER THAN A CODEC:
//    scrcpy can send opus, aac, flac or raw. Opus has no native decoder on
//    macOS. AAC does, but only via magic-cookie plumbing built from the
//    stream's AudioSpecificConfig, which fails in quiet, hard-to-diagnose
//    ways. Raw costs ~1.5 Mbps — nothing on a LAN, where jitter rather than
//    bandwidth is the constraint — and has no decoder to go wrong or add
//    latency. If Conduit ever needs a bandwidth-constrained link, AAC is the
//    upgrade path.
//

import Foundation
import AVFoundation

/// Plays the device's audio stream.
///
/// `enqueue(_:)` is safe to call from the audio connection's queue.
final class AudioPlayer {

    // MARK: - Format

    /// scrcpy captures device audio at 48 kHz, stereo, signed 16-bit.
    /// Source: AudioCapture / AudioCodec defaults in the v4.1 server.
    static let sampleRate: Double = 48_000
    static let channelCount: AVAudioChannelCount = 2

    // MARK: - Engine

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    /// Frames handed to the engine. Diagnostics only.
    private(set) var playedFrameCount: Int = 0

    /// Serialises engine start/stop against packets arriving on the
    /// network queue.
    private let lock = NSLock()
    private var isRunning = false

    // MARK: - Init

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        ) else {
            Log.audio.info("could not build output format")
            return nil
        }
        self.format = format

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        do {
            // Prepare pulls the graph into a ready state so the first
            // scheduled buffer is not delayed by allocation.
            engine.prepare()
            try engine.start()
            player.play()
            isRunning = true
            Log.audio.notice("engine started (\(Int(Self.sampleRate)) Hz, \(Self.channelCount) ch)")
        } catch {
            Log.audio.error("engine failed to start — \(error.localizedDescription)")
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }

        player.stop()
        engine.stop()
        isRunning = false
        playedFrameCount = 0
        Log.audio.info("engine stopped")
    }

    // MARK: - Playback

    /// Enqueue one packet of interleaved s16le PCM.
    ///
    /// Safe to call from the network queue. Silently drops the packet if
    /// the engine is not running — audio is disposable, and stalling the
    /// reader to wait for it would back up the socket.
    func enqueue(pcm data: Data) {
        lock.lock()
        let running = isRunning
        lock.unlock()
        guard running, !data.isEmpty else { return }

        // Two bytes per sample, interleaved across channels.
        let bytesPerFrame = 2 * Int(Self.channelCount)
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = buffer.floatChannelData else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        // s16 -> normalised float, de-interleaving into planar channels.
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let scale = Float(Int16.max)
            for frame in 0..<frameCount {
                let base = frame * Int(Self.channelCount)
                for channel in 0..<Int(Self.channelCount) {
                    // The wire is little-endian; so is every Mac Conduit runs on,
                    // but be explicit rather than relying on host order.
                    let sample = Int16(littleEndian: samples[base + channel])
                    channels[channel][frame] = Float(sample) / scale
                }
            }
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
        playedFrameCount += frameCount
    }
}
