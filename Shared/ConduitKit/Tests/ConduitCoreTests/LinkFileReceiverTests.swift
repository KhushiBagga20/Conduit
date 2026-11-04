//
//  LinkFileReceiverTests.swift
//  ConduitCoreTests
//
//  Files arriving over Conduit Link, into a temporary folder: kept only when
//  every byte is there and the hash matches, never under a name that could
//  escape the folder or hide.
//

import ConduitProtocol
import ConduitState
import CryptoKit
import Foundation
import Testing
@testable import ConduitCore

@MainActor
@Suite("Files from the phone over the Link")
struct LinkFileReceiverTests {

    let folder: URL
    let store = ConduitStore()
    let receiver: LinkFileReceiver
    let peer = LinkPeer(id: "PHONE", name: "S24 Ultra", platform: .android, publicKey: Data(), lastSeen: Date())

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-receive-\(UUID().uuidString)")
        store.preferences.phoneDownloadsPath = folder.path
        receiver = LinkFileReceiver(store: store)
    }

    private func offer(_ id: UInt32, name: String, size: Int, index: Int? = nil, count: Int? = nil) -> Result<Void, ProtocolError> {
        var payload: [String: JSONValue] = ["transferID": .int(Int64(id)), "name": .string(name), "size": .int(Int64(size))]
        if let index, let count {
            payload["index"] = .int(Int64(index))
            payload["count"] = .int(Int64(count))
        }
        return receiver.offer(payload, from: peer)
    }

    private func send(_ id: UInt32, _ bytes: Data, pieces: Int = 3) {
        let size = (bytes.count + pieces - 1) / pieces
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            receiver.chunk(FileChunk(transferID: id, offset: UInt64(offset), bytes: bytes[offset ..< end]), from: peer)
            offset = end
        }
    }

    private func finish(_ id: UInt32, hash: String) -> Result<Void, ProtocolError> {
        receiver.finish(["transferID": .int(Int64(id)), "sha256": .string(hash)], from: peer)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func visibleFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    @Test("a file arrives whole, under its own name, beside one already there")
    func arrives() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: folder.appendingPathComponent("IMG_1.jpg"))

        let bytes = Data((0 ..< 100_003).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        #expect(throws: Never.self) { try offer(1, name: "IMG_1.jpg", size: bytes.count).get() }
        // Nothing visible until the hash checks out.
        #expect(try visibleFiles() == ["IMG_1.jpg"])
        send(1, bytes)
        #expect(throws: Never.self) { try finish(1, hash: Self.sha256(bytes)).get() }

        #expect(try visibleFiles() == ["IMG_1 2.jpg", "IMG_1.jpg"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("IMG_1 2.jpg")) == bytes)
        let row = try #require(store.files.transfers.first)
        #expect(row.status == .done && row.bytesDone == UInt64(bytes.count))
        #expect(row.savedTo?.lastPathComponent == "IMG_1 2.jpg")
        #expect(store.activity.first?.title == "S24 Ultra sent a file")
        // No hidden piece left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
    }

    @Test("a damaged or short file is not kept")
    func damaged() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data(repeating: 9, count: 5_000)

        #expect(throws: Never.self) { try offer(2, name: "a.bin", size: bytes.count).get() }
        send(2, bytes)
        #expect(throws: ProtocolError.self) { try finish(2, hash: String(repeating: "0", count: 64)).get() }

        #expect(throws: Never.self) { try offer(3, name: "b.bin", size: bytes.count).get() }
        send(3, bytes.prefix(4_000))
        #expect(throws: ProtocolError.self) { try finish(3, hash: Self.sha256(bytes)).get() }

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(store.files.transfers.allSatisfy { if case .failed = $0.status { true } else { false } })
    }

    @Test("pieces out of order stop the file and tell the phone")
    func outOfOrder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var abandoned: [UInt32] = []
        receiver.onAbandoned = { _, id in abandoned.append(id) }

        #expect(throws: Never.self) { try offer(4, name: "c.bin", size: 10).get() }
        receiver.chunk(FileChunk(transferID: 4, offset: 5, bytes: Data(count: 5)), from: peer)
        #expect(abandoned == [4])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        // Too much is as bad as out of order.
        #expect(throws: Never.self) { try offer(5, name: "d.bin", size: 4).get() }
        receiver.chunk(FileChunk(transferID: 5, offset: 0, bytes: Data(count: 5)), from: peer)
        #expect(abandoned == [4, 5])
    }

    @Test("leaving mid-file clears it; a batch is one line of Activity")
    func batchesAndLeaving() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0 ..< 3 {
            let bytes = Data([UInt8(index)])
            #expect(throws: Never.self) { try offer(UInt32(10 + index), name: "p\(index).jpg", size: 1, index: index, count: 3).get() }
            send(UInt32(10 + index), bytes, pieces: 1)
            #expect(throws: Never.self) { try finish(UInt32(10 + index), hash: Self.sha256(bytes)).get() }
        }
        #expect(store.activity.filter { $0.kind == .transferCompleted }.map(\.title) == ["S24 Ultra sent 3 files"])

        #expect(throws: Never.self) { try offer(20, name: "e.bin", size: 100).get() }
        send(20, Data(count: 50), pieces: 1)
        receiver.peerLeft(peer.id)
        #expect(try visibleFiles() == ["p0.jpg", "p1.jpg", "p2.jpg"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 3)
    }

    @Test("names cannot leave the folder, hide, or overflow the disk's limit")
    func names() {
        #expect(LinkFileReceiver.safeName("../../etc/passwd") == "_.._etc_passwd")
        #expect(LinkFileReceiver.safeName(".hidden") == "hidden")
        #expect(LinkFileReceiver.safeName("a:b\nc.txt") == "a_b_c.txt")
        #expect(LinkFileReceiver.safeName("   ") == "File from phone")
        let long = LinkFileReceiver.safeName(String(repeating: "é", count: 300) + ".jpeg")
        #expect(long.utf8.count <= 200 && long.hasSuffix(".jpeg"))
    }
}
