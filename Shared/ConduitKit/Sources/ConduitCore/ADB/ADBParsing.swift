//
//  ADBParsing.swift
//  ConduitCore
//
//  Pure parsers for adb's text output, kept apart from process handling so
//  every format quirk is covered by a unit test instead of a phone.
//

import ConduitState
import Foundation

nonisolated enum ADBParsing {

    struct Device: Sendable, Equatable {
        let serial: String
        /// "device", "unauthorized", "offline", "authorizing", …
        let state: String
        let model: String?

        var isReady: Bool { state == "device" }

        /// Wireless serials are `host:port` or an mDNS service name.
        var transport: PhoneTransport {
            serial.contains(":") || serial.contains("._adb-tls-connect.") ? .wifi : .usb
        }
    }

    /// One device list: the body of `adb devices -l`, or of a single
    /// `adb track-devices -l` update. Fields are whitespace-separated;
    /// `-l` appends `key:value` pairs.
    static func deviceList(_ text: String) -> [Device] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("List of devices") else { return nil }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { return nil }
            let model = fields.dropFirst(2)
                .first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            return Device(serial: String(fields[0]), state: String(fields[1]), model: model)
        }
    }

    /// `adb track-devices` frames each update as four hex digits of length
    /// followed by that many bytes. Returns complete updates and leaves any
    /// partial one in `buffer`.
    static func trackUpdates(from buffer: inout Data) -> [String] {
        var updates: [String] = []
        while buffer.count >= 4 {
            let lengthText = String(decoding: buffer.prefix(4), as: UTF8.self)
            guard let length = Int(lengthText, radix: 16) else {
                // Not a length prefix: the stream is not what we think it
                // is. Drop it rather than parse garbage as devices.
                buffer.removeAll()
                break
            }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            updates.append(String(decoding: buffer[start ..< start + length], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex ..< start + length)
        }
        return updates
    }

    struct PhoneProperties: Sendable, Equatable {
        let hardwareSerial: String
        let name: String
        let model: String?
        let manufacturer: String?
        let osVersion: String?
    }

    /// The shell command whose output `phoneProperties` parses: one value
    /// per line, in this order.
    static let phonePropertiesCommand =
        "getprop ro.serialno; getprop ro.product.model; getprop ro.product.manufacturer; "
        + "getprop ro.build.version.release; settings get global device_name"

    static func phoneProperties(_ output: String, fallbackSerial: String) -> PhoneProperties {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func value(_ index: Int) -> String? {
            guard index < lines.count else { return nil }
            let text = lines[index]
            return text.isEmpty || text == "null" ? nil : text
        }
        let model = value(1)
        let manufacturer = value(2)
        let name = value(4) ?? [manufacturer?.capitalized, model].compactMap { $0 }.joined(separator: " ")
        return PhoneProperties(
            hardwareSerial: value(0) ?? Self.hardwareSerialHint(fromSerial: fallbackSerial) ?? fallbackSerial,
            name: name.isEmpty ? "Android phone" : name,
            model: model,
            manufacturer: manufacturer,
            osVersion: value(3))
    }

    /// Wireless debugging advertises `adb-<serial>-<suffix>`; adb names the
    /// transport after it (`adb-<serial>-<suffix>._adb-tls-connect._tcp`).
    /// Both carry the hardware serial, which is what lets one phone on USB
    /// and Wi-Fi be recognised as the same phone.
    static func hardwareSerialHint(fromServiceName name: String) -> String? {
        guard name.hasPrefix("adb-") else { return nil }
        let body = name.dropFirst(4)
        guard let dash = body.lastIndex(of: "-") else { return nil }
        let serial = body[..<dash]
        return serial.isEmpty ? nil : String(serial)
    }

    static func hardwareSerialHint(fromSerial serial: String) -> String? {
        guard let range = serial.range(of: "._adb-tls-connect.") else { return nil }
        return hardwareSerialHint(fromServiceName: String(serial[..<range.lowerBound]))
    }

    /// `adb forward tcp:0 …` prints the port it allocated.
    static func allocatedPort(_ output: String) -> UInt16? {
        UInt16(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isNoRouteToHost(_ output: String) -> Bool {
        output.lowercased().contains("no route to host")
    }

    /// `adb connect` exits 0 even when it fails, so read the text.
    static func connectSucceeded(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("connected to") && !text.contains("failed") && !text.contains("cannot")
    }
}
