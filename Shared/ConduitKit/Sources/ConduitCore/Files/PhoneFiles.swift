//
//  PhoneFiles.swift
//  ConduitCore
//
//  The phone's shared storage, for the Files page: browsing, and moving
//  files and whole folders both ways with progress. Over adb — so over USB,
//  Wi-Fi debugging or the phone's hotspot — through adb's own sync protocol.
//
//  Transfers run one at a time, each can be cancelled, and nothing is ever
//  overwritten: a name already taken gets " 2", as Finder does.
//

import AppKit
import ConduitMedia
import ConduitState
import Foundation

@MainActor
final class PhoneFiles {

    private let adb: ADB
    private let state: FilesState
    private var serial: String?
    private var useV2: [String: Bool] = [:]
    private var listing: Task<Void, Never>?
    private var queue: [Job] = []
    private var running: Job?

    /// A transfer waiting or under way. `work` runs off the main thread.
    private struct Job {
        typealias Work = @Sendable (_ connection: ADBSyncConnection, _ cancel: CancelFlag,
                                   _ total: @escaping @Sendable (UInt64) -> Void,
                                   _ moved: @escaping @Sendable (UInt64) -> Void) throws -> URL?
        let id: UUID
        let direction: FileTransfer.Direction
        let work: Work
        let cancel = CancelFlag()
        var openWhenDone = false
    }

    init(adb: ADB, state: FilesState) {
        self.adb = adb
        self.state = state
    }

    // MARK: - Which phone

    /// Browse this phone, or nothing with nil. A cable pulled and Wi-Fi
    /// taking over is a new serial for the same phone; the folder stays.
    func use(serial: String?) {
        guard serial != self.serial else { return }
        self.serial = serial
        state.isAvailable = serial != nil
        guard let serial else {
            listing?.cancel()
            state.entries = []
            state.isLoading = false
            return
        }
        Task { [weak self] in
            let features = await Task.detached { (try? ADBSyncConnection.features(serial: serial)) ?? [] }.value
            guard let self, self.serial == serial else { return }
            useV2[serial] = features.isSuperset(of: ["ls_v2", "stat_v2"])
            open(state.folder)
            startNext()
        }
    }

    // MARK: - Browsing

    func open(_ path: String) {
        guard let serial else { return }
        let folder = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        state.folder = folder
        state.isLoading = true
        state.error = nil
        listing?.cancel()
        let v2 = useV2[serial] ?? false

        listing = Task { [weak self] in
            let result = await Task.detached { () -> Result<[PhoneFile], Error> in
                Result { try Self.read(folder, serial: serial, v2: v2) }
            }.value
            guard let self, !Task.isCancelled, state.folder == folder else { return }
            state.isLoading = false
            switch result {
            case .success(let files):
                state.entries = files
            case .failure(let error):
                state.entries = []
                state.error = error.localizedDescription
            }
        }
    }

    func refresh() {
        open(state.folder)
    }

    /// A folder's contents: folders first, then by name, hidden files left
    /// out as Finder leaves them out. Links (Android has a few) are followed
    /// to find out whether they are folders.
    nonisolated private static func read(_ folder: String, serial: String, v2: Bool) throws -> [PhoneFile] {
        let connection = try ADBSyncConnection(serial: serial, useV2: v2)
        defer { connection.close() }
        let files: [PhoneFile] = try connection.list(folder).compactMap { entry in
            guard !entry.name.hasPrefix(".") else { return nil }
            let path = folder == "/" ? "/\(entry.name)" : "\(folder)/\(entry.name)"
            var kind = entry.kind
            var size = entry.size
            if kind == .link, let target = try connection.stat(path) {
                kind = target.kind
                size = target.size
            }
            guard kind == .file || kind == .directory || kind == .link else { return nil }
            return PhoneFile(path: path, name: entry.name, isFolder: kind != .file, size: size,
                             modified: Date(timeIntervalSince1970: TimeInterval(entry.modified)))
        }
        return files.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Changing the phone

    func createFolder(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serial, !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
        let path = "\(state.folder)/\(name)"
        let adb = self.adb
        Task { [weak self] in
            let ok = await Task.detached { adb.run(["-s", serial, "shell", "mkdir -p -- \(PhoneShell.quote(path))"]).ok }.value
            guard let self else { return }
            if !ok { state.error = "The phone didn't make the folder “\(name)”." }
            refresh()
        }
    }

    /// Deletes only inside shared storage, never the storage itself.
    func delete(_ files: [PhoneFile]) {
        guard let serial else { return }
        let inside = FilesState.root + "/"
        let paths = files.map(\.path).filter { $0.hasPrefix(inside) && $0.count > inside.count }
        guard !paths.isEmpty else { return }
        let adb = self.adb
        Task { [weak self] in
            let failed = await Task.detached {
                paths.filter { !adb.run(["-s", serial, "shell", "rm -rf -- \(PhoneShell.quote($0))"]).ok }
            }.value
            guard let self else { return }
            if !failed.isEmpty {
                state.error = "The phone didn't delete \(failed.count == 1 ? "one item" : "\(failed.count) items")."
            }
            refresh()
        }
    }

    // MARK: - Moving files

    func download(_ files: [PhoneFile], to folder: URL, openWhenDone: Bool = false) {
        // The folder may not exist yet — ~/S24U on first use.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let id = UUID()
            state.transfers.append(FileTransfer(id: id, name: file.name, direction: .toMac,
                                                bytesTotal: file.isFolder ? 0 : file.size))
            var job = Job(id: id, direction: .toMac) { connection, cancel, total, moved in
                let destination = Self.unused(folder.appendingPathComponent(file.name))
                guard file.isFolder else {
                    try connection.pull(file.path, to: destination) { moved($0); return !cancel.isCancelled }
                    return destination
                }
                let plan = try Self.plan(phoneFolder: file.path, into: destination, connection)
                total(plan.files.reduce(0) { $0 + $1.size })
                for folder in [destination] + plan.folders {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                }
                var done: UInt64 = 0
                for item in plan.files {
                    try connection.pull(item.remote, to: item.local) { moved(done + $0); return !cancel.isCancelled }
                    done += item.size
                }
                return destination
            }
            job.openWhenDone = openWhenDone
            queue.append(job)
        }
        startNext()
    }

    func upload(_ urls: [URL]) {
        let into = state.folder
        for url in urls {
            let id = UUID()
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let size = isFolder ? 0 : UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            state.transfers.append(FileTransfer(id: id, name: url.lastPathComponent, direction: .toPhone, bytesTotal: size))
            queue.append(Job(id: id, direction: .toPhone) { connection, cancel, total, moved in
                let target = try Self.unused("\(into)/\(url.lastPathComponent)", connection)
                guard isFolder else {
                    try connection.push(url, to: target) { moved($0); return !cancel.isCancelled }
                    return nil
                }
                let plan = Self.plan(macFolder: url, into: target)
                total(plan.reduce(0) { $0 + $1.size })
                var done: UInt64 = 0
                for item in plan {
                    try connection.push(item.local, to: item.remote) { moved(done + $0); return !cancel.isCancelled }
                    done += item.size
                }
                return nil
            })
        }
        startNext()
    }

    /// A copy on this Mac, opened in its own app.
    func openCopy(_ file: PhoneFile) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Conduit Files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        download([file], to: folder, openWhenDone: true)
    }

    func cancel(_ id: UUID) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index)
            state.update(id) { $0.status = .cancelled }
        } else if running?.id == id {
            running?.cancel.cancel()
        }
    }

    func clearFinished() {
        state.transfers.removeAll(where: \.isFinished)
    }

    // MARK: - The queue

    private func startNext() {
        guard running == nil, let serial, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = job
        state.update(job.id) { $0.status = .moving }
        let v2 = useV2[serial] ?? false
        let throttle = Throttle(interval: 0.1)

        let state = self.state
        let id = job.id
        let total: @Sendable (UInt64) -> Void = { bytes in
            Task { @MainActor in state.update(id) { $0.bytesTotal = bytes } }
        }
        let moved: @Sendable (UInt64) -> Void = { bytes in
            guard throttle.ready() else { return }
            Task { @MainActor in state.update(id) { $0.bytesDone = bytes } }
        }

        Task { [weak self] in
            let result = await Task.detached { () -> Result<URL?, Error> in
                Result {
                    let connection = try ADBSyncConnection(serial: serial, useV2: v2)
                    defer { connection.close() }
                    return try job.work(connection, job.cancel, total, moved)
                }
            }.value
            self?.finished(job, result)
        }
    }

    private func finished(_ job: Job, _ result: Result<URL?, Error>) {
        running = nil
        state.update(job.id) { transfer in
            switch result {
            case .success(let url):
                transfer.status = .done
                transfer.bytesDone = transfer.bytesTotal
                transfer.savedTo = url
            case .failure(ADBSync.Failure.cancelled):
                transfer.status = .cancelled
            case .failure(let error):
                transfer.status = .failed(error.localizedDescription)
            }
        }
        if job.openWhenDone, case .success(let url?) = result {
            NSWorkspace.shared.open(url)
        }
        if job.direction == .toPhone { refresh() }
        startNext()
    }

    // MARK: - Planning

    private struct Item: Sendable {
        let remote: String
        let local: URL
        let size: UInt64
    }

    /// Every file and folder under a phone folder, mapped into a Mac one.
    /// Links are not followed: a link back up the tree would never end.
    nonisolated private static func plan(phoneFolder: String, into local: URL,
                                         _ connection: ADBSyncConnection) throws -> (files: [Item], folders: [URL]) {
        var files: [Item] = []
        var folders: [URL] = []
        for entry in try connection.list(phoneFolder) {
            let remote = "\(phoneFolder)/\(entry.name)"
            let target = local.appendingPathComponent(entry.name)
            switch entry.kind {
            case .directory:
                folders.append(target)
                let inner = try plan(phoneFolder: remote, into: target, connection)
                files += inner.files
                folders += inner.folders
            case .file:
                files.append(Item(remote: remote, local: target, size: entry.size))
            case .link, .other:
                continue
            }
        }
        return (files, folders)
    }

    /// Every file under a Mac folder, mapped onto the phone. The phone makes
    /// the folders as the files arrive.
    nonisolated private static func plan(macFolder: URL, into remote: String) -> [Item] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: macFolder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        let base = macFolder.standardizedFileURL.pathComponents.count
        return walker.compactMap { element -> Item? in
            guard let url = element as? URL,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { return nil }
            let relative = url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            return Item(remote: "\(remote)/\(relative)", local: url, size: UInt64(values.fileSize ?? 0))
        }
    }

    /// A Mac name not taken yet: "photo.jpg", then "photo 2.jpg".
    nonisolated static func unused(_ url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        for number in 2 ... 9999 {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(stem) \(number)\(suffix)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url.deletingLastPathComponent().appendingPathComponent("\(stem) \(UUID().uuidString)\(suffix)")
    }

    /// A phone name not taken yet, the same way.
    nonisolated private static func unused(_ path: String, _ connection: ADBSyncConnection) throws -> String {
        guard try connection.stat(path) != nil else { return path }
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        for number in 2 ... 999 {
            let candidate = "\(folder)/\(stem) \(number)\(suffix)"
            if try connection.stat(candidate) == nil { return candidate }
        }
        return "\(folder)/\(stem) \(UUID().uuidString)\(suffix)"
    }
}

/// Set once, read from any thread.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

/// Lets progress through a few times a second: a 64 KiB chunk at USB speed
/// arrives hundreds of times a second, far more often than anyone can read.
nonisolated final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func ready() -> Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
    }
}
