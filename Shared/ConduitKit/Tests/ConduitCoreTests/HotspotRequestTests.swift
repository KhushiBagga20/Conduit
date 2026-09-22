//
//  HotspotRequestTests.swift
//  ConduitCoreTests
//
//  The Bluetooth hotspot request against Shared/Protocol/vectors/hotspot.json,
//  which Conduit for Android checks too.
//

import CryptoKit
import Foundation
import Testing
@testable import ConduitCore

@Suite("Hotspot request")
struct HotspotRequestTests {

    private let vectors: [String: Any]

    init() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Protocol/vectors/hotspot.json")
        vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
    }

    private func data(_ key: String) -> Data {
        let text = vectors[key] as? String ?? ""
        var bytes = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    private var fields: HotspotRequest.Fields {
        HotspotRequest.Fields(macID: data("macID"), phoneID: data("phoneID"),
                              timestamp: UInt64(vectors["timestamp"] as? Int ?? 0), nonce: data("nonce"))
    }

    @Test("the statement and the wire bytes match the vector, and the signature verifies")
    func matchesVector() throws {
        let mac = try P256.Signing.PrivateKey(rawRepresentation: data("macPrivate"))
        #expect(mac.publicKey.x963Representation == data("macPublic"))
        #expect(LinkCrypto.deviceID(forPublicKey: data("macPublic")) == vectors["macID"] as? String)
        #expect(LinkCrypto.deviceID(forPublicKey: data("phonePublic")) == vectors["phoneID"] as? String)

        #expect(HotspotRequest.statement(fields) == data("statement"))
        #expect(HotspotRequest.encode(fields, signature: data("signature")) == data("wire"))
        #expect(LinkCrypto.verify(data("signature"), of: data("statement"), by: data("macPublic")))

        let decoded = try #require(HotspotRequest.decode(data("wire")))
        #expect(decoded.fields == fields)
        #expect(decoded.signature == data("signature"))
    }

    @Test("a request this Mac makes is addressed to one phone and signed by this Mac")
    func madeRequests() throws {
        let identity = LinkIdentity(signingKey: P256.Signing.PrivateKey())
        let phoneID = String(repeating: "ab", count: 16)
        let wire = try HotspotRequest.make(identity: identity, phoneID: phoneID,
                                           now: Date(timeIntervalSince1970: 1_758_500_000))

        let (fields, signature) = try #require(HotspotRequest.decode(wire))
        #expect(fields.macID == HotspotRequest.deviceIDBytes(identity.deviceID))
        #expect(fields.phoneID == HotspotRequest.deviceIDBytes(phoneID))
        #expect(fields.timestamp == 1_758_500_000_000)
        #expect(LinkCrypto.verify(signature, of: HotspotRequest.statement(fields), by: identity.publicKey))
        #expect(wire.count <= 182, "fits one write at the MTU macOS negotiates")

        #expect(HotspotRequest.decode(Data([2]) + wire.dropFirst()) == nil)
        #expect(HotspotRequest.deviceIDBytes("not hex") == nil)
    }
}
