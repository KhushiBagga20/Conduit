//
//  H264Decoder.swift
//  ConduitMedia
//
//  H.264 decoding pipeline using VideoToolbox.
//  Real-time decode tuning.
//
//  Receives raw H.264 Annex-B data from ScrcpyVideoParser,
//  extracts SPS/PPS from CONFIG packets, creates a
//  VTDecompressionSession, and decodes frames into CVPixelBuffers.
//
//  Does NOT render. Does NOT block the main thread.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class H264Decoder {

    // MARK: - Decoder State

    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var spsData: Data?
    private var ppsData: Data?

    // MARK: - Diagnostics

    /// Incremented from the VT callback thread. Read for display purposes only.
    private(set) var decodedFrameCount: Int = 0
    private(set) var decodedWidth: Int = 0
    private(set) var decodedHeight: Int = 0

    private var lastDecodeLogTime: TimeInterval = 0
    private let decodeLogInterval: TimeInterval = 2.0

    // MARK: - Output

    /// Called on a VideoToolbox internal thread with each decoded pixel buffer.
    /// Wired by StreamConnection to feed frames into the VideoRenderer.
    var onDecodedFrame: ((CVPixelBuffer, CMTime) -> Void)?

    // MARK: - Public API

    /// Process a single parsed video frame.
    /// Call from the network queue (not the main thread).
    func processFrame(_ frame: ScrcpyVideoFrame) {
        if frame.header.isConfig {
            handleConfigPacket(frame.data)
        } else {
            decodeVideoFrame(frame)
        }
    }

    /// Tear down VideoToolbox resources. Safe to call multiple times.
    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        spsData = nil
        ppsData = nil
        decodedFrameCount = 0
        decodedWidth = 0
        decodedHeight = 0
        // Clear callback to break any potential retain cycles.
        onDecodedFrame = nil
    }

    deinit {
        // VTDecompressionSessionInvalidate must be called before dealloc.
        invalidate()
    }

    // MARK: - CONFIG Packet — SPS/PPS Extraction

    /// Parse Annex-B CONFIG data to extract SPS and PPS NAL units,
    /// then create (or recreate) the VideoToolbox decoder.
    private func handleConfigPacket(_ data: Data) {
        let nalUnits = Self.parseAnnexBNALUnits(data)

        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[nal.startIndex] & 0x1F
            switch nalType {
            case 7: // SPS
                spsData = nal
                Log.decoder.debug("SPS received (\(nal.count) bytes)")
            case 8: // PPS
                ppsData = nal
                Log.decoder.debug("PPS received (\(nal.count) bytes)")
            default:
                Log.decoder.debug("CONFIG contains NAL type \(nalType) (ignored)")
            }
        }

        guard let sps = spsData, let pps = ppsData else {
            Log.decoder.info("CONFIG incomplete — need both SPS and PPS")
            return
        }

        createDecoder(sps: sps, pps: pps)
    }

    // MARK: - Decoder Session Creation

    /// Create a CMVideoFormatDescription from SPS+PPS and initialize
    /// a VTDecompressionSession. Invalidates any existing session first.
    private func createDecoder(sps: Data, pps: Data) {
        // Tear down existing session before creating a new one.
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
            formatDescription = nil
        }

        // --- CMVideoFormatDescription from H.264 parameter sets ---

        var fd: CMVideoFormatDescription?

        let fdStatus: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress,
                      let ppsBase = ppsRaw.baseAddress else {
                    return errSecParam
                }
                let spsPtr = spsBase.assumingMemoryBound(to: UInt8.self)
                let ppsPtr = ppsBase.assumingMemoryBound(to: UInt8.self)

                var pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes: [Int] = [sps.count, pps.count]

                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fd
                )
            }
        }

        guard fdStatus == noErr, let formatDesc = fd else {
            Log.decoder.error("CMVideoFormatDescriptionCreateFromH264ParameterSets failed — \(fdStatus)")
            return
        }

        formatDescription = formatDesc

        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        decodedWidth = Int(dims.width)
        decodedHeight = Int(dims.height)
        Log.decoder.info("format description — \(decodedWidth)x\(decodedHeight)")

        // --- VTDecompressionSession ---

        let imageAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        var session: VTDecompressionSession?

        // outputCallback = nil → use the handler-based VTDecompressionSessionDecodeFrame.
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: imageAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard sessionStatus == noErr, let newSession = session else {
            Log.decoder.error("VTDecompressionSessionCreate failed — \(sessionStatus)")
            return
        }

        // Latency tuning. VideoToolbox defaults favour throughput and
        // power over responsiveness, which is the wrong trade for mirroring.
        //
        // RealTime tells the decoder to emit each frame as soon as it can
        // rather than batching work. Turning MaximizePowerEfficiency off
        // stops it from coalescing decodes to save energy. Both are
        // advisory — a failure here costs latency, not correctness, so it
        // is logged rather than treated as fatal.
        let realTimeStatus = VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        if realTimeStatus != noErr {
            Log.decoder.info("could not set RealTime — \(realTimeStatus) (continuing)")
        }

        let powerStatus = VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_MaximizePowerEfficiency,
            value: kCFBooleanFalse
        )
        if powerStatus != noErr {
            Log.decoder.info("could not disable power-efficiency mode — \(powerStatus) (continuing)")
        }

        decompressionSession = newSession
        decodedFrameCount = 0
        Log.decoder.notice("session created ✓ (real-time)")
    }

    // MARK: - Frame Decoding

    /// Convert Annex-B frame data to AVCC, wrap in CMSampleBuffer,
    /// and submit to the VTDecompressionSession for decoding.
    private func decodeVideoFrame(_ frame: ScrcpyVideoFrame) {
        guard let session = decompressionSession,
              let fd = formatDescription else {
            return // No decoder yet — silently drop (CONFIG not received yet).
        }

        // Convert Annex-B start codes → AVCC 4-byte length prefixes.
        let avccData = Self.annexBToAVCC(frame.data)
        guard !avccData.isEmpty else { return }

        // Create CMBlockBuffer containing the AVCC data.
        guard let blockBuffer = Self.createBlockBuffer(from: avccData) else {
            Log.decoder.error("CMBlockBuffer creation failed")
            return
        }

        // Create CMSampleBuffer with timing from the scrcpy frame header.
        let pts = CMTimeMake(value: frame.header.pts, timescale: 1_000_000)

        guard let sampleBuffer = Self.createSampleBuffer(
            blockBuffer: blockBuffer,
            formatDescription: fd,
            pts: pts,
            dataLength: avccData.count
        ) else {
            Log.decoder.error("CMSampleBuffer creation failed")
            return
        }

        // Submit for asynchronous decoding.
        let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, presentationTimeStamp, _ in
            guard let self = self else { return }

            if status != noErr {
                Log.decoder.error("decode callback error — \(status)")
                return
            }
            guard let pixelBuffer = imageBuffer else { return }

            self.decodedFrameCount += 1
            self.logDecodedFrameIfNeeded()
            self.onDecodedFrame?(pixelBuffer, presentationTimeStamp)
        }

        if status != noErr {
            if status == kVTInvalidSessionErr {
                Log.decoder.info("session invalidated — will recreate on next CONFIG")
                decompressionSession = nil
                formatDescription = nil
            } else {
                Log.decoder.error("VTDecompressionSessionDecodeFrame submit error — \(status)")
            }
        }
    }

    // MARK: - Rate-Limited Decode Logging

    private func logDecodedFrameIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDecodeLogTime >= decodeLogInterval {
            Log.decoder.debug("decoded #\(decodedFrameCount) — \(decodedWidth)x\(decodedHeight)")
            lastDecodeLogTime = now
        }
    }

    // MARK: - CoreMedia Helpers

    /// Allocate a CMBlockBuffer and copy `data` into it.
    private static func createBlockBuffer(from data: Data) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,           // CoreMedia allocates
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let bb = blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        return status == kCMBlockBufferNoErr ? bb : nil
    }

    /// Wrap a CMBlockBuffer in a CMSampleBuffer with format + timing info.
    private static func createSampleBuffer(
        blockBuffer: CMBlockBuffer,
        formatDescription: CMVideoFormatDescription,
        pts: CMTime,
        dataLength: Int
    ) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    // MARK: - Annex-B → NAL Unit Parsing

    /// Parse an H.264 Annex-B byte stream into individual NAL units
    /// (without start codes). Handles both 3-byte (00 00 01) and
    /// 4-byte (00 00 00 01) start codes.
    ///
    /// Safe: no unsafe pointer tricks — operates on a `[UInt8]` copy.
    static func parseAnnexBNALUnits(_ data: Data) -> [Data] {
        guard data.count >= 4 else { return [] }

        let bytes = [UInt8](data)
        let count = bytes.count
        var nalUnits: [Data] = []
        var nalStart = -1   // byte index where current NAL unit data begins
        var i = 0

        while i < count - 2 {
            // Check for 4-byte start code first (superset of 3-byte).
            if i < count - 3
                && bytes[i] == 0 && bytes[i + 1] == 0
                && bytes[i + 2] == 0 && bytes[i + 3] == 1
            {
                if nalStart >= 0, i > nalStart {
                    nalUnits.append(Data(bytes[nalStart..<i]))
                }
                nalStart = i + 4
                i += 4
                continue
            }
            // Check for 3-byte start code.
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if nalStart >= 0, i > nalStart {
                    nalUnits.append(Data(bytes[nalStart..<i]))
                }
                nalStart = i + 3
                i += 3
                continue
            }
            i += 1
        }

        // Emit final NAL unit (from last start code to end of data).
        if nalStart >= 0, nalStart < count {
            nalUnits.append(Data(bytes[nalStart..<count]))
        }

        return nalUnits
    }

    // MARK: - Annex-B → AVCC Conversion

    /// Convert Annex-B start codes to AVCC 4-byte big-endian length prefixes.
    /// Required because VideoToolbox expects AVCC-formatted sample data.
    static func annexBToAVCC(_ data: Data) -> Data {
        let nalUnits = parseAnnexBNALUnits(data)
        guard !nalUnits.isEmpty else { return Data() }

        var avcc = Data()
        avcc.reserveCapacity(data.count) // AVCC is roughly the same size.

        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            // 4-byte big-endian length prefix
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        return avcc
    }
}
