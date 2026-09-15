//
//  CoreLogicTests.swift
//  ConduitCoreTests
//
//  adb output formats, phone grouping and server arguments — everything in
//  the owner that can be checked without a phone attached.
//

import ConduitProtocol
import ConduitState
import Foundation
import Testing
@testable import ConduitCore

@Suite("adb parsing")
struct ADBParsingTests {

    @Test("devices -l output, including an unauthorised phone and an mDNS transport")
    func deviceList() {
        let output = """
        List of devices attached
        RZCY60JS0PM            device usb:34603008X product:e3qxins model:SM_S928B device:e3q transport_id:2
        adb-RZCY60JS0PM-eKgcmu._adb-tls-connect._tcp device product:e3qxins model:SM_S928B device:e3q transport_id:3
        192.168.1.20:37001     unauthorized transport_id:4

        """
        let devices = ADBParsing.deviceList(output)
        #expect(devices.count == 3)
        #expect(devices[0] == .init(serial: "RZCY60JS0PM", state: "device", model: "SM S928B"))
        #expect(devices[0].transport == .usb)
        #expect(devices[1].transport == .wifi)
        #expect(devices[2].state == "unauthorized" && devices[2].transport == .wifi && !devices[2].isReady)
    }

    @Test("track-devices frames updates with a hex length and may split them anywhere")
    func trackUpdates() {
        let first = "RZCY60JS0PM\tdevice\n"
        let stream = Data((String(format: "%04x", first.utf8.count) + first + "0000").utf8)

        var buffer = Data()
        var updates: [String] = []
        for byte in stream {
            buffer.append(byte)
            updates += ADBParsing.trackUpdates(from: &buffer)
        }
        #expect(updates == [first, ""])
        #expect(buffer.isEmpty)
        #expect(ADBParsing.deviceList(updates[0]).first?.serial == "RZCY60JS0PM")
        #expect(ADBParsing.deviceList(updates[1]).isEmpty)
    }

    @Test("phone properties, with the user's device name preferred")
    func properties() {
        let named = ADBParsing.phoneProperties("RZCY60JS0PM\nSM-S928B\nsamsung\n16\nKhushi's S24 Ultra\n",
                                               fallbackSerial: "x")
        #expect(named.hardwareSerial == "RZCY60JS0PM")
        #expect(named.name == "Khushi's S24 Ultra")
        #expect(named.model == "SM-S928B" && named.manufacturer == "samsung" && named.osVersion == "16")

        let unnamed = ADBParsing.phoneProperties("\nPixel 8\nGoogle\n15\nnull\n",
                                                 fallbackSerial: "adb-38BX1-a1b2._adb-tls-connect._tcp")
        #expect(unnamed.name == "Google Pixel 8")
        #expect(unnamed.hardwareSerial == "38BX1")
    }

    @Test("hardware serial hints from Wireless debugging names")
    func serialHints() {
        #expect(ADBParsing.hardwareSerialHint(fromServiceName: "adb-RZCY60JS0PM-eKgcmu") == "RZCY60JS0PM")
        #expect(ADBParsing.hardwareSerialHint(fromServiceName: "adb-with-dash-123-XyZ") == "with-dash-123")
        #expect(ADBParsing.hardwareSerialHint(fromServiceName: "studio-abc") == nil)
        #expect(ADBParsing.hardwareSerialHint(fromSerial: "adb-RZCY60JS0PM-eKgcmu._adb-tls-connect._tcp") == "RZCY60JS0PM")
        #expect(ADBParsing.hardwareSerialHint(fromSerial: "192.168.1.20:5555") == nil)
    }

    @Test("forward and connect output")
    func commandOutput() {
        #expect(ADBParsing.allocatedPort("53817\n") == 53817)
        #expect(ADBParsing.allocatedPort("error: more than one device") == nil)
        #expect(ADBParsing.connectSucceeded("connected to 10.0.0.5:37001\n"))
        #expect(ADBParsing.connectSucceeded("already connected to 10.0.0.5:37001\n"))
        #expect(!ADBParsing.connectSucceeded("failed to connect to '10.0.0.5:37001': Connection refused\n"))
        #expect(!ADBParsing.connectSucceeded("cannot connect to 10.0.0.5:37001: No route to host\n"))
        #expect(ADBParsing.isNoRouteToHost("failed to connect to '10.0.0.5:45423': No route to host\n"))
        #expect(!ADBParsing.isNoRouteToHost("failed to connect to '10.0.0.5:45423': Connection refused\n"))
    }
}

@Suite("Phone registry")
struct PhoneRegistryTests {

    private let properties = ADBParsing.PhoneProperties(
        hardwareSerial: "RZCY60JS0PM", name: "S24 Ultra", model: "SM-S928B", manufacturer: "samsung", osVersion: "16")

    @Test("one phone on USB and Wi-Fi is one device, connected over USB")
    func mergesTransports() {
        let attached = [
            AttachedTransport(device: .init(serial: "RZCY60JS0PM", state: "device", model: nil), properties: properties),
            AttachedTransport(device: .init(serial: "adb-RZCY60JS0PM-eKgcmu._adb-tls-connect._tcp", state: "device", model: nil),
                              properties: properties),
        ]
        let phones = PhoneRegistry.phones(attached: attached, known: [:], preferredID: nil)
        #expect(phones.count == 1)
        #expect(phones[0].connection == .connected(.usb))
        #expect(phones[0].transports == [.usb, .wifi])
        #expect(phones[0].features[.mirroring] == .available)
        #expect(phones[0].features[.calls] == .planned)

        let targets = PhoneRegistry.targets(for: "RZCY60JS0PM", attached: attached)
        #expect(targets.map(\.transport) == [.usb, .wifi])
    }

    @Test("an anonymous Wi-Fi transport is hidden until its properties load")
    func anonymousWiFiHidden() {
        let usb = AttachedTransport(device: .init(serial: "RZCY60JS0PM", state: "device", model: nil), properties: properties)
        let pending = AttachedTransport(device: .init(serial: "192.168.1.20:45423", state: "device", model: "SM S928B"))
        #expect(PhoneRegistry.phones(attached: [usb, pending], known: [:], preferredID: nil).count == 1)

        let resolved = AttachedTransport(device: pending.device, properties: properties)
        let merged = PhoneRegistry.phones(attached: [usb, resolved], known: [:], preferredID: nil)
        #expect(merged.count == 1 && merged[0].transports == [.usb, .wifi])

        let unauthorised = AttachedTransport(device: .init(serial: "192.168.1.20:45423", state: "unauthorized", model: nil))
        #expect(PhoneRegistry.phones(attached: [unauthorised], known: [:], preferredID: nil).first?.connection == .unauthorized)
    }

    @Test("remembered phones appear disconnected; unauthorised ones say so")
    func knownAndUnauthorised() {
        let known = ["OLD1": KnownPhone(id: "OLD1", name: "Old phone", lastSeen: Date(timeIntervalSince1970: 1))]
        let attached = [AttachedTransport(device: .init(serial: "NEW2", state: "unauthorized", model: nil))]
        let phones = PhoneRegistry.phones(attached: attached, known: known, preferredID: "OLD1")

        #expect(phones.count == 2)
        let old = phones.first { $0.id == "OLD1" }
        #expect(old?.connection == .disconnected && old?.isPreferred == true)
        #expect(old?.features[.mirroring] == .requiresSetup)
        #expect(phones.first { $0.id == "NEW2" }?.connection == .unauthorized)
        #expect(PhoneRegistry.targets(for: "NEW2", attached: attached).isEmpty)
    }

    @Test("features the phone's Android version cannot support are labelled unsupported")
    func versionGates() {
        let android10 = PhoneRegistry.features(connected: true, osVersion: "10")
        #expect(android10[.audio] == .unsupported)
        #expect(android10[.camera] == .unsupported)
        #expect(PhoneRegistry.features(connected: true, osVersion: "14")[.audio] == .available)
    }
}

@Suite("scrcpy server")
struct ScrcpyServerTests {

    @Test("arguments match scrcpy v4.1 Options.java, with a unique socket")
    func arguments() {
        var options = MirroringOptions()
        options.lowLatency = true
        options.audio = false
        let configuration = ScrcpyServer.Configuration(serial: "S", scid: 0x1234abcd, options: options,
                                                       videoSource: .camera(facing: .front))

        #expect(configuration.socketName == "scrcpy_1234abcd")
        #expect(configuration.devicePath == "/data/local/tmp/conduit-scrcpy-1234abcd.jar")
        #expect(configuration.arguments == [
            "scid=1234abcd", "log_level=info", "video=true", "audio=false", "audio_codec=raw",
            "control=true", "tunnel_forward=true", "video_bit_rate=4000000", "max_size=1024",
            "max_fps=60", "stay_awake=true", "video_source=camera", "camera_facing=front",
        ])
    }

    @Test("random socket ids stay within 31 bits")
    func scidRange() {
        for _ in 0 ..< 1000 {
            let scid = ScrcpyServer.Configuration(serial: "S", options: MirroringOptions()).scid
            #expect(scid >= 1 && scid <= 0x7FFF_FFFF)
        }
    }

    @Test("the bundled server matches its pinned checksum")
    func bundledBinary() throws {
        let url = try #require(Bundle.module.url(forResource: "scrcpy-server-v4.1", withExtension: nil))
        #expect(try Data(contentsOf: url).count > 50_000)
    }
}
