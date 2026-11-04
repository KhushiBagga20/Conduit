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

    /// Reads `dumpsys package` output for a granted runtime or install
    /// permission, e.g. `android.permission.WRITE_SECURE_SETTINGS: granted=true`.
    static func permissionGranted(_ permission: String, in dumpsys: String) -> Bool {
        dumpsys.split(whereSeparator: \.isNewline).contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix(permission + ":") && text.contains("granted=true")
        }
    }

    /// The data a receiver returned to `am broadcast`, from a line like
    /// `Broadcast completed: result=0, data="guarding"`. Nil when no
    /// receiver answered.
    static func broadcastResultData(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("Broadcast completed") }),
              let start = line.range(of: "data=\"")
        else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// Quote a value for the phone's shell: `adb shell` joins its arguments
    /// into one command line, so `$`, spaces or quotes would be interpreted.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `adb tcpip 5555` answers "restarting in TCP mode port: 5555".
    static func tcpModeArmed(_ output: String, port: UInt16) -> Bool {
        output.contains("restarting in TCP mode port: \(port)")
    }

    /// `adb usb` answers "restarting in USB mode"; a phone already in USB
    /// mode says so too.
    static func usbModeRestored(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("restarting in usb mode") || text.contains("already in usb mode")
    }

    static func isNoRouteToHost(_ output: String) -> Bool {
        output.lowercased().contains("no route to host")
    }

    /// `adb connect` exits 0 even when it fails, so read the text.
    static func connectSucceeded(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("connected to") && !text.contains("failed") && !text.contains("cannot")
    }

    // MARK: - Android's media index

    /// A file as Android's MediaStore knows it.
    struct MediaEntry: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case image, video, other }
        let id: Int64
        let kind: Kind
        /// When the photo or video was taken, or else when the file arrived
        /// on the phone — the nearest thing Android keeps to a creation date.
        let created: Date?

        /// MediaProvider serves a cached thumbnail for photos and videos.
        var thumbnailURI: String? {
            switch kind {
            case .image: "content://media/external/images/media/\(id)/thumbnail"
            case .video: "content://media/external/video/media/\(id)/thumbnail"
            case .other: nil
            }
        }
    }

    /// One query for a folder. The path comes last, since a file name may
    /// hold the ", " that separates the other columns. The folder is quoted
    /// for the phone's shell and, inside that, for SQL.
    static func mediaIndexCommand(folder: String) -> String {
        let clause = "_data LIKE '\(folder.replacingOccurrences(of: "'", with: "''"))/%'"
        return "content query --uri content://media/external/file "
            + "--projection _id:media_type:date_added:datetaken:_data --where \(PhoneShell.quote(clause))"
    }

    /// Rows like `Row: 0 _id=12, media_type=1, date_added=1755964978,
    /// datetaken=1755964977024, _data=/storage/…/IMG_1.jpg`, keyed by path.
    /// Only files directly in `folder` count; LIKE also matches deeper ones.
    static func mediaIndex(_ output: String, folder: String) -> [String: MediaEntry] {
        var entries: [String: MediaEntry] = [:]
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            guard let dataRange = line.range(of: ", _data=") else { continue }
            let path = String(line[dataRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard (path as NSString).deletingLastPathComponent == folder else { continue }

            var fields: [String: String] = [:]
            for pair in line[..<dataRange.lowerBound].split(separator: ",") {
                let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                // The first pair carries the "Row: 0 " prefix.
                fields[String(parts[0].split(separator: " ").last ?? "")] = parts[1]
            }
            guard let id = fields["_id"].flatMap({ Int64($0) }) else { continue }
            let kind: MediaEntry.Kind = switch fields["media_type"] {
            case "1": .image
            case "3": .video
            default: .other
            }
            let taken = fields["datetaken"].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
            let added = fields["date_added"].flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            entries[path] = MediaEntry(id: id, kind: kind, created: taken ?? added)
        }
        return entries
    }

    // MARK: - Wireless readiness

    /// What the phone says, over the cable, about being reached over Wi-Fi.
    struct WirelessProbe: Sendable, Equatable {
        let debuggingOn: Bool
        /// Where Wireless debugging listens; it moves whenever it restarts.
        let port: UInt16?
        /// The phone's address on the Wi-Fi network it has joined.
        let wifiAddress: String?
    }

    /// One shell command: Wireless debugging's switch, its port, every IPv4
    /// address with its interface, and the TCP sockets adbd listens on.
    ///
    /// MEASURED on a Galaxy S24 Ultra (Android 16): service.adb.tls.port
    /// stays empty while Wireless debugging listens. adbd runs as the shell
    /// user (uid 2000), so its listening sockets give the port instead.
    static let wirelessProbeCommand =
        "echo \"wd=$(settings get global adb_wifi_enabled)\"; echo \"port=$(getprop service.adb.tls.port)\"; "
        + "ip -4 -o addr show 2>/dev/null; "
        + "cat /proc/net/tcp6 /proc/net/tcp 2>/dev/null | awk '$4==\"0A\" && $8==\"2000\" {print \"listen=\" $2}'"

    static func wirelessProbe(_ output: String) -> WirelessProbe {
        var debuggingOn = false
        var port: UInt16?
        var listening: UInt16?
        var address: String?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("wd=") {
                debuggingOn = line.dropFirst(3) == "1"
            } else if line.hasPrefix("port=") {
                port = UInt16(line.dropFirst(5)).flatMap { $0 > 0 ? $0 : nil }
            } else if line.hasPrefix("listen="), listening == nil,
                      let hex = line.split(separator: ":").last, let found = UInt16(hex, radix: 16),
                      found != HotspotAccess.port {
                // adb's own TCP port, when armed, is not Wireless debugging's.
                listening = found
            } else if address == nil, let found = wifiAddress(inIPLine: line) {
                address = found
            }
        }
        return WirelessProbe(debuggingOn: debuggingOn, port: port ?? (debuggingOn ? listening : nil), wifiAddress: address)
    }

    /// `30: wlan0    inet 192.168.31.5/24 brd …` gives 192.168.31.5. Only the
    /// Wi-Fi client interfaces count — wlan0, wlan1 — not the hotspot's own
    /// (swlan0, ap0) or mobile data (rmnet).
    static func wifiAddress(inIPLine line: String) -> String? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 4, fields[2] == "inet" else { return nil }
        let interface = fields[1]
        guard interface.hasPrefix("wlan"), interface.dropFirst(4).allSatisfy(\.isNumber) else { return nil }
        let address = String(fields[3].prefix { $0 != "/" })
        let octets = address.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return address
    }

    /// Whether two IPv4 addresses look like the same network. Only the first
    /// two numbers are compared: Wi-Fi networks are often wider than a /24,
    /// and a false "different network" would send someone down the wrong road.
    static func probablySameNetwork(_ a: String, _ b: String) -> Bool {
        let left = a.split(separator: "."), right = b.split(separator: ".")
        guard left.count == 4, right.count == 4 else { return false }
        return left.prefix(2) == right.prefix(2)
    }
}
