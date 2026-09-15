//
//  ScrcpyWireTests.swift
//  ConduitMediaTests
//
//  Pins the byte layouts the scrcpy client was physically tested with, so
//  any change to the media stack that alters what goes on the wire fails
//  here before it reaches a phone. Layouts: scrcpy v4.1 control_msg.c,
//  device_msg.c, Streamer.java, DesktopConnection.java.
//

import CoreGraphics
import Foundation
import Testing
@testable import ConduitMedia

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@Suite("Control messages")
struct ControlMessageTests {

    @Test("inject touch is 32 bytes in control_msg.c order")
    func injectTouch() {
        let data = ScrcpyControlMessage.injectTouch(
            action: .down, pointerId: ScrcpyPointerID.mouse, x: 100, y: 2000,
            screenWidth: 1080, screenHeight: 2340, pressure: 1.0,
            actionButton: .primary, buttons: .primary
        ).encode()

        #expect(data.count == 32)
        #expect(hex(data) ==
            "02" + "00" + "ffffffffffffffff"          // type, action, pointer id (-1)
            + "00000064" + "000007d0"                 // x, y
            + "0438" + "0924"                         // screen width, height
            + "ffff"                                  // pressure 1.0
            + "00000001" + "00000001")                // action button, buttons
    }

    @Test("inject scroll is 21 bytes with i16 fixed-point deltas")
    func injectScroll() {
        let data = ScrcpyControlMessage.injectScroll(
            x: 5, y: 6, screenWidth: 720, screenHeight: 1600,
            hScroll: 1.0, vScroll: -1.0, buttons: []
        ).encode()

        #expect(data.count == 21)
        #expect(hex(data) == "03" + "00000005" + "00000006" + "02d0" + "0640" + "7fff" + "8000" + "00000000")
    }

    @Test("inject keycode is 14 bytes")
    func injectKeycode() {
        let data = ScrcpyControlMessage.injectKeycode(action: .up, keycode: .enter, repeatCount: 2, metaState: 0x41).encode()
        #expect(hex(data) == "00" + "01" + "00000042" + "00000002" + "00000041")
    }

    @Test("text is capped at 300 bytes without splitting a character")
    func injectTextClipping() {
        let text = String(repeating: "a", count: 299) + "é"   // é is two bytes
        let data = ScrcpyControlMessage.injectText(text).encode()
        let length = Int(data[1]) << 24 | Int(data[2]) << 16 | Int(data[3]) << 8 | Int(data[4])
        #expect(length == 299)
        #expect(data.count == 5 + 299)
    }

    @Test("set clipboard carries sequence, paste flag and UTF-8 text")
    func setClipboard() {
        let data = ScrcpyControlMessage.setClipboard(sequence: 7, paste: true, text: "hi").encode()
        #expect(hex(data) == "09" + "0000000000000007" + "01" + "00000002" + "6869")
    }

    @Test("single-byte and two-byte messages")
    func smallMessages() {
        #expect(hex(ScrcpyControlMessage.backOrScreenOn(action: .down).encode()) == "0400")
        #expect(hex(ScrcpyControlMessage.setDisplayPower(on: false).encode()) == "0a00")
        #expect(hex(ScrcpyControlMessage.rotateDevice.encode()) == "0b")
        #expect(hex(ScrcpyControlMessage.expandNotificationPanel.encode()) == "05")
        #expect(hex(ScrcpyControlMessage.collapsePanels.encode()) == "07")
    }

    @Test("fixed-point conversions clamp instead of trapping")
    func fixedPoint() {
        #expect(ScrcpyControlMessage.floatToU16FixedPoint(0) == 0)
        #expect(ScrcpyControlMessage.floatToU16FixedPoint(0.5) == 0x8000)
        #expect(ScrcpyControlMessage.floatToU16FixedPoint(7) == 0xFFFF)
        #expect(ScrcpyControlMessage.floatToI16FixedPoint(-7) == Int16.min)
        #expect(ScrcpyControlMessage.floatToI16FixedPoint(0.5) == 0x4000)
    }
}

@Suite("Video stream parser")
struct VideoParserTests {

    /// The first bytes a scrcpy v4.1 server writes on the video socket.
    private func serverStream() -> Data {
        var data = Data([0])                                           // dummy byte
        var name = Data("Galaxy S24 Ultra".utf8)
        name.append(Data(count: 64 - name.count))                      // 64-byte name field
        data.append(name)
        data.append(Data([0x68, 0x32, 0x36, 0x34]))                    // "h264"
        data.append(Data([0x80, 0, 0, 0, 0, 0, 0x04, 0x38, 0, 0, 0x09, 0x24]))  // session: 1080×2340
        data.append(Data([0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4]))     // CONFIG frame header, 4 bytes
        data.append(Data([0, 0, 0, 1]))
        data.append(Data([0x20, 0, 0, 0, 0, 0, 0x03, 0xe8, 0, 0, 0, 2]))  // KEY frame, pts 1000, 2 bytes
        data.append(Data([0xAB, 0xCD]))
        return data
    }

    @Test("events arrive in order regardless of read boundaries")
    func parsesServerStream() {
        for chunkSize in [1, 3, 7, 1024] {
            var events: [ScrcpyParserEvent] = []
            let parser = ScrcpyVideoParser { events.append($0) }

            let stream = serverStream()
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunkSize, stream.count)
                parser.receive(stream.subdata(in: offset ..< end))
                offset = end
            }

            guard events.count == 6 else {
                Issue.record("chunk \(chunkSize): expected 6 events, got \(events.count)")
                continue
            }
            if case .dummyByteReceived = events[0] {} else { Issue.record("dummy byte") }
            if case .deviceInfoReceived(let info) = events[1] {
                #expect(info.deviceName == "Galaxy S24 Ultra")
            } else { Issue.record("device name") }
            if case .codecDetected(let codec) = events[2] { #expect(codec == .h264) } else { Issue.record("codec") }
            if case .videoSessionReceived(let session) = events[3] {
                #expect(session.width == 1080 && session.height == 2340 && !session.isClientResize)
            } else { Issue.record("session") }
            if case .videoFrameReceived(let config) = events[4] {
                #expect(config.header.isConfig && config.data.count == 4)
            } else { Issue.record("config frame") }
            if case .videoFrameReceived(let key) = events[5] {
                #expect(key.header.isKeyFrame && key.header.pts == 1000 && key.data == Data([0xAB, 0xCD]))
            } else { Issue.record("key frame") }
        }
    }

    @Test("an impossible payload size stops the parser until reset")
    func impossiblePayload() {
        var events: [ScrcpyParserEvent] = []
        let parser = ScrcpyVideoParser { events.append($0) }
        var stream = serverStream().prefix(1 + 64 + 4)
        stream.append(Data([0, 0, 0, 0, 0, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF]))
        parser.receive(Data(stream))

        guard case .error = parser.parserState else {
            Issue.record("expected error state")
            return
        }
        parser.receive(Data([0]))
        parser.reset()
        #expect(parser.parserState.description == "WAITING_FOR_DUMMY")
    }
}

@Suite("Device messages")
struct DeviceMessageTests {

    @Test("clipboard and ack messages parse across splits")
    func clipboardAndAck() {
        var messages: [ScrcpyDeviceMessage] = []
        let parser = ScrcpyDeviceMessageParser { messages.append($0) }
        let bytes = Data([0, 0, 0, 0, 5]) + Data("hello".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0, 9])

        for byte in bytes { parser.receive(Data([byte])) }

        #expect(messages.count == 2)
        if case .clipboard(let text) = messages.first { #expect(text == "hello") } else { Issue.record("clipboard") }
        if case .acknowledgeClipboard(let seq) = messages.last { #expect(seq == 9) } else { Issue.record("ack") }
    }

    @Test("an unknown message type desynchronises the parser")
    func unknownType() {
        let parser = ScrcpyDeviceMessageParser { _ in }
        parser.receive(Data([0x42, 0, 0]))
        #expect(parser.isDesynchronised)
    }
}

@Suite("H.264 helpers")
struct H264Tests {

    @Test("Annex-B start codes of both lengths become AVCC length prefixes")
    func annexBToAVCC() {
        let annexB = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0xCC])
        let avcc = H264Decoder.annexBToAVCC(annexB)
        #expect(hex(avcc) == "00000002" + "67aa" + "00000003" + "68bbcc")
    }
}

@Suite("Input mapping")
struct InputMappingTests {

    @Test("letterboxing under resizeAspect")
    func videoContentRect() {
        let wide = InputController.videoContentRect(
            videoSize: CGSize(width: 1080, height: 2340), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(wide.map { abs($0.width - 461.538) < 0.01 && $0.height == 1000 && abs($0.minX - 269.23) < 0.01 } == true)

        let tall = InputController.videoContentRect(
            videoSize: CGSize(width: 2340, height: 1080), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(tall.map { $0.width == 1000 && abs($0.height - 461.538) < 0.01 } == true)

        #expect(InputController.videoContentRect(videoSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)) == nil)
    }
}
