//
//  ADBSync.swift
//  ConduitCore
//
//  adb's file sync protocol — what `adb push` and `adb pull` speak — talked
//  directly to the local adb server. That is what lets Conduit show real
//  progress, read exact sizes (videos past 4 GB included), and never put a
//  file name through a shell.
//
//  Wire format from AOSP's packages/modules/adb (Apache 2.0):
//  file_sync_protocol.h and docs/dev/sync.md. Every sync message starts with
//  a 4-byte ASCII ID and a little-endian uint32; data moves in chunks of at
//  most 64 KiB; all integers are little-endian. A request to the adb server
//  itself is its length as four hex digits, then the text, answered OKAY or
//  FAIL (followed by a hex-length message).
//
//  Details the documents leave unsaid, checked against a Galaxy S24 Ultra:
//  a listing's DONE is a whole entry-sized record; SEND's mode is the file's
//  st_mode in decimal; one sync connection carries many requests.
//

import Darwin
import Foundation

nonisolated enum ADBSync {

    static let serverPort: UInt16 = 5037
    static let maximumChunk = 64 * 1024
    static let maximumPath = 1024

    enum Kind: Sendable, Equatable {
        case file, directory, link, other

        init(mode: UInt32) {
            switch mode & 0o170000 {
            case 0o040000: self = .directory
            case 0o100000: self = .file
            case 0o120000: self = .link
            default: self = .other
            }
        }
    }

    struct Entry: Sendable, Equatable {
        var name: String
        var mode: UInt32
        var size: UInt64
        /// Seconds since the Unix epoch, from the phone's clock.
        var modified: Int64

        var kind: Kind { Kind(mode: mode) }
    }

    enum Failure: LocalizedError, Equatable {
        /// The adb server refused — usually that the phone is not attached.
        case server(String)
        /// The phone refused — a missing file, or no permission.
        case device(String)
        case unexpected(String)
        case connection(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .server(let message): "adb: \(message)"
            case .device(let message): "The phone said: \(message)"
            case .unexpected(let detail): "The phone answered in a way Conduit didn't expect (\(detail))."
            case .connection(let detail): "Lost the connection to the phone (\(detail))."
            case .cancelled: "Cancelled."
            }
        }
    }

    // MARK: - Encoding

    /// A request to the adb server: four hex digits of length, then the text.
    static func hostRequest(_ text: String) -> Data {
        let body = Data(text.utf8)
        return Data(String(format: "%04x", body.count).utf8) + body
    }

    /// A sync message header — the ID and a little-endian uint32 — and its payload.
    static func message(_ id: String, _ payload: Data = Data(), length: UInt32? = nil) -> Data {
        precondition(id.utf8.count == 4)
        var data = Data(id.utf8)
        data.append(littleEndian: length ?? UInt32(payload.count))
        data.append(payload)
        return data
    }

    /// SEND's payload: the path, a comma, and the file mode in decimal.
    static func sendPayload(path: String, mode: UInt32) -> Data {
        Data("\(path),\(mode)".utf8)
    }

    // MARK: - Decoding

    /// Reads little-endian fields from a record, in order.
    struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func id() -> String {
            defer { offset += 4 }
            return String(decoding: data[offset ..< offset + 4], as: UTF8.self)
        }

        mutating func u32() -> UInt32 {
            defer { offset += 4 }
            return data[offset ..< offset + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }

        mutating func u64() -> UInt64 {
            defer { offset += 8 }
            return data[offset ..< offset + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        mutating func i64() -> Int64 { Int64(bitPattern: u64()) }
    }

    /// sync_dent_v1: id, mode, size, mtime, namelen — 20 bytes.
    static let dentV1Size = 20
    /// sync_dent_v2: id, error, dev, ino, mode, nlink, uid, gid, size,
    /// atime, mtime, ctime, namelen — 76 bytes.
    static let dentV2Size = 76
    /// sync_stat_v1: id, mode, size, mtime — 16 bytes.
    static let statV1Size = 16
    /// sync_stat_v2: as dent_v2 without namelen — 72 bytes.
    static let statV2Size = 72

    struct DentHeader: Equatable {
        var id: String
        var error: UInt32
        var mode: UInt32
        var size: UInt64
        var mtime: Int64
        var nameLength: UInt32
    }

    static func dentV1(_ record: Data) -> DentHeader {
        var r = Reader(record)
        let id = r.id()
        let mode = r.u32(), size = r.u32(), mtime = r.u32(), nameLength = r.u32()
        return DentHeader(id: id, error: 0, mode: mode, size: UInt64(size), mtime: Int64(mtime), nameLength: nameLength)
    }

    static func dentV2(_ record: Data) -> DentHeader {
        var r = Reader(record)
        let id = r.id()
        let error = r.u32()
        _ = r.u64(); _ = r.u64()                     // dev, ino
        let mode = r.u32()
        _ = r.u32(); _ = r.u32(); _ = r.u32()        // nlink, uid, gid
        let size = r.u64()
        _ = r.i64()                                  // atime
        let mtime = r.i64()
        _ = r.i64()                                  // ctime
        let nameLength = r.u32()
        return DentHeader(id: id, error: error, mode: mode, size: size, mtime: mtime, nameLength: nameLength)
    }

    /// The stat record, or nil if the path does not exist.
    static func statV1(_ record: Data) -> Entry? {
        var r = Reader(record)
        _ = r.id()
        let mode = r.u32(), size = r.u32(), mtime = r.u32()
        // A missing path comes back as all zeros.
        guard mode != 0 else { return nil }
        return Entry(name: "", mode: mode, size: UInt64(size), modified: Int64(mtime))
    }

    static func statV2(_ record: Data) -> (entry: Entry?, error: UInt32) {
        var r = Reader(record)
        _ = r.id()
        let error = r.u32()
        _ = r.u64(); _ = r.u64()
        let mode = r.u32()
        _ = r.u32(); _ = r.u32(); _ = r.u32()
        let size = r.u64()
        _ = r.i64()
        let mtime = r.i64()
        guard error == 0 else { return (nil, error) }
        return (Entry(name: "", mode: mode, size: size, modified: mtime), 0)
    }
}

extension Data {
    nonisolated mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
