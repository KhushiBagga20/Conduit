//
//  VideoRenderer.swift
//  ConduitMedia
//
//  Native rendering of decoded CVPixelBuffers.
//  Low-latency display path.
//
//  Wraps AVSampleBufferDisplayLayer. Accepts CVPixelBuffers from the
//  H264Decoder callback, wraps them in CMSampleBuffers, and enqueues
//  them for immediate display.
//
//  LATENCY: every sample carries the DisplayImmediately attachment, so the
//  layer presents each frame as soon as it dequeues it and ignores
//  presentation timing entirely. For live mirroring there is nothing to
//  synchronise against — a frame is already as late as it will ever be by
//  the time it arrives, so holding it for a PTS only adds delay.
//
//  Thread-safe for enqueue() — called from the VideoToolbox callback thread.
//

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

public final class VideoRenderer {

    // MARK: - Display Layer

    /// The layer that renders decoded video frames.
    /// Add this as a sublayer (or backing layer) of an NSView.
    public let displayLayer: AVSampleBufferDisplayLayer

    // MARK: - Diagnostics

    /// Frames discarded because the layer was not ready. Non-zero means the
    /// display path is the bottleneck rather than the link.
    public private(set) var droppedFrameCount: Int = 0

    // MARK: - Private

    private var timebase: CMTimebase?

    // MARK: - Init

    init() {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black

        // A control timebase is still attached so the layer has a coherent
        // clock, but it is never advanced per frame — DisplayImmediately
        // bypasses it. Previously this was stepped to each frame's PTS,
        // which made the clock jump forward on every arrival and could
        // strand already-queued frames.
        var tb: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        )
        if status == noErr, let tb = tb {
            timebase = tb
            CMTimebaseSetRate(tb, rate: 1.0)
            CMTimebaseSetTime(tb, time: .zero)
            displayLayer.controlTimebase = tb
        } else {
            Log.renderer.error("CMTimebaseCreateWithSourceClock failed — \(status)")
        }
    }

    // MARK: - Public API

    /// Enqueue a decoded pixel buffer for display.
    ///
    /// Safe to call from any thread (VideoToolbox callback thread in practice).
    /// The frame is displayed as soon as possible — the timebase is advanced
    /// to the frame's PTS to minimise latency for real-time mirroring.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let sampleBuffer = createSampleBuffer(from: pixelBuffer, pts: pts) else {
            return
        }

        // Present as soon as the layer dequeues this sample.
        Self.markDisplayImmediately(sampleBuffer)

        let renderer = displayLayer.sampleBufferRenderer

        if renderer.status == .failed {
            Log.renderer.error("layer failed — \(renderer.error?.localizedDescription ?? "unknown")")
            renderer.flush()
        }

        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        } else {
            // The layer is backed up. Dropping is correct for live mirroring —
            // a stale frame is worth less than the next one — but a rising
            // count means display, not the network, is the bottleneck.
            droppedFrameCount += 1
        }
    }

    /// Attach kCMSampleAttachmentKey_DisplayImmediately so the layer shows
    /// the frame on dequeue instead of scheduling it against the timebase.
    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 else { return }

        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    /// Flush all enqueued frames and reset the timebase.
    /// Call on disconnect or before a new stream.
    func flush() {
        Log.renderer.info("flushing display layer")
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        droppedFrameCount = 0
        if let tb = timebase {
            CMTimebaseSetTime(tb, time: .zero)
            CMTimebaseSetRate(tb, rate: 1.0)
        }
    }

    // MARK: - CMSampleBuffer Creation

    /// Wrap a CVPixelBuffer + PTS into a CMSampleBuffer suitable for
    /// AVSampleBufferDisplayLayer.
    private func createSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        pts: CMTime
    ) -> CMSampleBuffer? {
        // Create a format description from the pixel buffer dimensions/format.
        var formatDescription: CMVideoFormatDescription?
        let fdStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard fdStatus == noErr, let fd = formatDescription else { return nil }

        // Wrap the pixel buffer in a CMSampleBuffer with the given PTS.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sbStatus == noErr ? sampleBuffer : nil
    }
}
