//
//  HotspotRequest.swift
//  ConduitCore
//
//  The request this Mac sends over Bluetooth LE when it wants the phone's
//  hotspot — Shared/Protocol/README.md §8a. When the Mac has no network it
//  cannot reach the phone over Conduit Link, so it signs a short request with
//  its identity key instead, addressed to one paired phone.
//

import CryptoKit
import Foundation

nonisolated enum HotspotRequest {

    static let serviceUUID = "9D99F667-22A5-4207-B9F0-CF2A1F80D81B"
    static let characteristicUUID = "A9FE1931-A845-4B54-811D-9095A568370A"
    static let version: UInt8 = 1

    struct Fields: Equatable, Sendable {
        /// Raw 16-byte device IDs (§4).
        let macID: Data
        let phoneID: Data
        /// Milliseconds since the Unix epoch.
        let timestamp: UInt64
        let nonce: Data
    }

    /// `"conduit-hotspot-v1" ‖ macID ‖ phoneID ‖ timestamp ‖ nonce`
    static func statement(_ fields: Fields) -> Data {
        Data("conduit-hotspot-v1".utf8) + fields.macID + fields.phoneID + bigEndian(fields.timestamp) + fields.nonce
    }

    static func encode(_ fields: Fields, signature: Data) -> Data {
        Data([version]) + fields.macID + fields.phoneID + bigEndian(fields.timestamp) + fields.nonce + signature
    }

    /// A signed request from this Mac to one paired phone.
    static func make(identity: LinkIdentity, phoneID: String, now: Date = Date()) throws -> Data {
        guard let macID = deviceIDBytes(identity.deviceID), let phone = deviceIDBytes(phoneID) else {
            throw LinkCryptoError.badKey
        }
        let fields = Fields(macID: macID, phoneID: phone,
                            timestamp: UInt64(now.timeIntervalSince1970 * 1000),
                            nonce: Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }))
        return encode(fields, signature: try LinkCrypto.sign(statement(fields), with: identity.signingKey))
    }

    /// The fields and signature of a request, or nil if it is not one.
    static func decode(_ data: Data) -> (fields: Fields, signature: Data)? {
        let header = 1 + 16 + 16 + 8 + 16
        guard data.count > header, data.first == version else { return nil }
        let bytes = [UInt8](data)
        let timestamp = bytes[33 ..< 41].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (Fields(macID: Data(bytes[1 ..< 17]), phoneID: Data(bytes[17 ..< 33]),
                       timestamp: timestamp, nonce: Data(bytes[41 ..< 57])),
                Data(bytes[header...]))
    }

    /// A device ID's 32 hex characters as its 16 raw bytes.
    static func deviceIDBytes(_ id: String) -> Data? {
        guard id.count == 32 else { return nil }
        var bytes = Data(capacity: 16)
        var index = id.startIndex
        while index < id.endIndex {
            let next = id.index(index, offsetBy: 2)
            guard let byte = UInt8(id[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
