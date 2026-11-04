//
//  LinkFileReceiver.swift
//  ConduitCore
//
//  Files the phone sends over Conduit Link: `file.offer`, the pieces on the
//  file channel, then `file.finish` with the SHA-256 (spec §6 Files, §7).
//
//  Each file is written to a hidden file in the downloads folder and hashed
//  as it arrives. It takes its real name only once every byte is there and
//  the hash matches, so a half-sent file never looks like a finished one.
//  Progress shows in the Files page's transfers, like a download over adb.
//
//  Logs and Activity say that files came and how many, never their names.
//

import ConduitMedia
import ConduitProtocol
import ConduitState
import CryptoKit
import Foundation

@MainActor
final class LinkFileReceiver {

    /// The receiver gave up on a file mid-way; the phone should stop sending it.
    var onAbandoned: (_ peerID: String, _ transferID: UInt32) -> Void = { _, _ in }

    private final class Incoming {
        let peerID: String
        let transferID: UInt32
        /// The row in the Files page's transfers.
        let rowID = UUID()
        let name: String
        let size: UInt64
        let folder: URL
        let partial: URL
        let handle: FileHandle
        /// Where this file sits in what the phone is sending at once.
        let batch: (index: Int, count: Int)?
        var hasher = SHA256()
        var received: UInt64 = 0
        var reported: UInt64 = 0

        init(peerID: String, transferID: UInt32, name: String, size: UInt64, folder: URL, partial: URL,
             handle: FileHandle, batch: (index: Int, count: Int)?) {
            self.peerID = peerID
            self.transferID = transferID
            self.name = name
            self.size = size
            self.folder = folder
            self.partial = partial
            self.handle = handle
            self.batch = batch
        }
    }

    private let store: ConduitStore
    private var incoming: [String: Incoming] = [:]
    /// Files finished from each phone's current batch, for one Activity line.
    private var finishedInBatch: [String: Int] = [:]

    /// A phone may send a few files side by side; more is a bug.
    private static let maxPerPhone = 4
    /// Room left on the disk after the file, so a phone cannot fill it.
    private static let spareSpace: Int64 = 512 << 20
    private static let partialPrefix = ".conduit-"
    private static let partialSuffix = ".part"

    init(store: ConduitStore) {
        self.store = store
    }

    private static func key(_ peerID: String, _ transferID: UInt32) -> String { "\(peerID)/\(transferID)" }

    func owns(row id: UUID) -> Bool { incoming.values.contains { $0.rowID == id } }

    // MARK: - The phone's commands

    func offer(_ payload: [String: JSONValue]?, from peer: LinkPeer) -> Result<Void, ProtocolError> {
        guard let payload,
              let rawID = payload["transferID"]?.intValue, let transferID = UInt32(exactly: rawID),
              let rawName = payload["name"]?.stringValue,
              let rawSize = payload["size"]?.intValue, let size = UInt64(exactly: rawSize)
        else { return .failure(ProtocolError(.invalidRequest, "The offer was missing its ID, name or size.")) }

        let key = Self.key(peer.id, transferID)
        guard incoming[key] == nil else {
            return .failure(ProtocolError(.invalidRequest, "That transfer is already under way."))
        }
        guard incoming.values.filter({ $0.peerID == peer.id }).count < Self.maxPerPhone else {
            return .failure(ProtocolError(.busy, "This Mac is already taking several files from the phone."))
        }

        let folder = store.preferences.phoneDownloadsFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failure(ProtocolError(.internal, "Conduit couldn't make the folder \(folder.lastPathComponent) on this Mac."))
        }
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard Int64(clamping: size) <= free - Self.spareSpace else {
            return .failure(ProtocolError(.internal, "There isn't enough free space on this Mac."))
        }
        Self.clearAbandonedPartials(in: folder, keeping: Set(incoming.values.map(\.partial)))

        let partial = folder.appendingPathComponent("\(Self.partialPrefix)\(UUID().uuidString)\(Self.partialSuffix)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial)
        else { return .failure(ProtocolError(.internal, "Conduit couldn't write to \(folder.lastPathComponent) on this Mac.")) }

        let batch: (Int, Int)? = {
            guard let index = payload["index"]?.intValue, let count = payload["count"]?.intValue,
                  count > 0, (0 ..< count).contains(index) else { return nil }
            return (Int(index), Int(count))
        }()
        let file = Incoming(peerID: peer.id, transferID: transferID, name: Self.safeName(rawName), size: size,
                            folder: folder, partial: partial, handle: handle, batch: batch)
        incoming[key] = file
        if batch?.0 == 0 { finishedInBatch[peer.id] = 0 }

        var row = FileTransfer(id: file.rowID, name: file.name, direction: .toMac, bytesTotal: size)
        row.status = .moving
        store.files.transfers.append(row)
        CoreLog.engine.notice("the phone is sending a file of \(size) bytes")
        return .success(())
    }

    func chunk(_ chunk: FileChunk, from peer: LinkPeer) {
        // Pieces still in flight when a transfer was stopped are expected.
        guard let file = incoming[Self.key(peer.id, chunk.transferID)] else { return }
        guard chunk.offset == file.received else {
            abandon(file, because: "Parts of the file arrived out of order.")
            return
        }
        guard file.received + UInt64(chunk.bytes.count) <= file.size else {
            abandon(file, because: "The phone sent more than it said it would.")
            return
        }
        do {
            try file.handle.write(contentsOf: chunk.bytes)
        } catch {
            abandon(file, because: "This Mac couldn't save the file. Is the disk full?")
            return
        }
        file.hasher.update(data: chunk.bytes)
        file.received += UInt64(chunk.bytes.count)

        // A redraw for every 256 KiB piece would be wasted; about every 1%.
        let step = max(file.size / 100, 1 << 20)
        if file.received - file.reported >= step || file.received == file.size {
            file.reported = file.received
            let received = file.received
            store.files.update(file.rowID) { $0.bytesDone = received }
        }
    }

    func finish(_ payload: [String: JSONValue]?, from peer: LinkPeer) -> Result<Void, ProtocolError> {
        guard let rawID = payload?["transferID"]?.intValue, let transferID = UInt32(exactly: rawID),
              let file = incoming[Self.key(peer.id, transferID)]
        else { return .failure(ProtocolError(.invalidRequest, "This Mac isn't expecting that file.")) }
        let expected = payload?["sha256"]?.stringValue?.lowercased()

        let digest = file.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard file.received == file.size, digest == expected else {
            CoreLog.engine.notice("a file from the phone arrived incomplete or damaged")
            discard(file, status: .failed("The file arrived damaged, so it wasn't kept."))
            return .failure(ProtocolError(.invalidRequest, "The file arrived damaged, so the Mac didn't keep it."))
        }

        try? file.handle.close()
        incoming[Self.key(file.peerID, file.transferID)] = nil
        let destination = PhoneFiles.unused(file.folder.appendingPathComponent(file.name))
        do {
            try FileManager.default.moveItem(at: file.partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: file.partial)
            store.files.update(file.rowID) { $0.status = .failed("This Mac couldn't save the file.") }
            return .failure(ProtocolError(.internal, "The Mac couldn't save the file."))
        }
        store.files.update(file.rowID) {
            $0.bytesDone = file.size
            $0.status = .done
            $0.savedTo = destination
        }
        CoreLog.engine.notice("received a file from the phone")
        recordFinished(file, from: peer)
        return .success(())
    }

    /// The phone stopped sending a file.
    func cancel(_ payload: [String: JSONValue]?, from peer: LinkPeer) {
        guard let rawID = payload?["transferID"]?.intValue, let transferID = UInt32(exactly: rawID),
              let file = incoming[Self.key(peer.id, transferID)] else { return }
        CoreLog.engine.notice("the phone stopped sending a file")
        discard(file, status: .cancelled)
    }

    // MARK: - This Mac's side

    /// The person pressed stop on a row in the transfers.
    func cancel(row id: UUID) {
        guard let file = incoming.values.first(where: { $0.rowID == id }) else { return }
        discard(file, status: .cancelled)
        onAbandoned(file.peerID, file.transferID)
    }

    /// The phone's connection ended: nothing more of its files will come.
    func peerLeft(_ peerID: String) {
        for file in incoming.values where file.peerID == peerID {
            discard(file, status: .failed("The phone disconnected before the file arrived."))
        }
        finishedInBatch[peerID] = nil
    }

    private func abandon(_ file: Incoming, because reason: String) {
        CoreLog.engine.notice("stopped taking a file from the phone")
        discard(file, status: .failed(reason))
        onAbandoned(file.peerID, file.transferID)
    }

    private func discard(_ file: Incoming, status: FileTransfer.Status) {
        incoming[Self.key(file.peerID, file.transferID)] = nil
        try? file.handle.close()
        try? FileManager.default.removeItem(at: file.partial)
        store.files.update(file.rowID) { $0.status = status }
    }

    /// One Activity line per batch: "sent 12 files", not twelve lines.
    private func recordFinished(_ file: Incoming, from peer: LinkPeer) {
        let count = (finishedInBatch[peer.id] ?? 0) + 1
        finishedInBatch[peer.id] = count
        guard file.batch.map({ $0.index == $0.count - 1 }) ?? true else { return }
        finishedInBatch[peer.id] = 0
        let title = count == 1 ? "\(peer.name) sent a file" : "\(peer.name) sent \(count) files"
        store.record(ActivityEvent(kind: .transferCompleted, title: title,
                                   detail: "Saved in \(file.folder.lastPathComponent)"))
    }

    // MARK: - Names and leftovers

    /// The phone names the file; the Mac decides what that may mean. No
    /// folders, nothing hidden, nothing too long for the disk.
    nonisolated static func safeName(_ raw: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var name = raw.components(separatedBy: unsafe).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return "File from phone" }

        // APFS allows 255 bytes; keep the extension when trimming.
        let maxBytes = 200
        guard name.utf8.count > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : ".\(ext)"
        if suffix.isEmpty { stem = name }
        while stem.utf8.count + suffix.utf8.count > maxBytes { stem.removeLast() }
        return stem + suffix
    }

    /// Hidden pieces of files a crash or a pulled plug left behind.
    private static func clearAbandonedPartials(in folder: URL, keeping active: Set<URL>) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        let items = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where item.lastPathComponent.hasPrefix(partialPrefix)
            && item.lastPathComponent.hasSuffix(partialSuffix) && !active.contains(item) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff { try? manager.removeItem(at: item) }
        }
    }
}
