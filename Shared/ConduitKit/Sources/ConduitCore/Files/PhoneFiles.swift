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
//  Editing in place is the one exception, by request: a file opened for
//  editing is written back over itself each time it is saved on the Mac —
//  unless the phone's own copy changed meanwhile, in which case the save
//  goes beside it, so neither change is lost.
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
        /// Runs on the main actor once the job has finished, either way.
        var onFinish: ((Result<URL?, Error>) -> Void)?
    }

    /// One file being edited on this Mac: how its working copy and the
    /// phone's copy last looked, to notice a save and to notice a conflict.
    private struct Watch {
        var modified: Date
        var size: Int
        /// Set when the working copy changes; a save follows once it holds
        /// still, because apps write a document in more than one step.
        var changedAt: Date?
        var phoneModified: Int64
        var phoneSize: UInt64
        var saving = false
        var saveAgain = false
    }

    private var watches: [UUID: Watch] = [:]
    private var watcher: Timer?

    /// Opens a file in its Mac app. Tests put something quieter here.
    var openInApp: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Where working copies live. Old ones are cleared out at launch.
    nonisolated static var editingFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.khushi.Conduit/Editing", isDirectory: true)
    }

    init(adb: ADB, state: FilesState) {
        self.adb = adb
        self.state = state
        Self.clearOldWorkingCopies()
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

    // MARK: - Editing in place

    func edit(_ file: PhoneFile) {
        guard !file.isFolder else { return }
        let session = EditSession(name: file.name, phonePath: file.path)
        state.editing.append(session)
        let folder = Self.editingFolder.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transferID = UUID()
        state.transfers.append(FileTransfer(id: transferID, name: file.name, direction: .toMac, bytesTotal: file.size))
        let phone = Box<ADBSync.Entry?>(nil)
        var job = Job(id: transferID, direction: .toMac) { connection, cancel, _, moved in
            // The phone's copy as it was when opened: a later save checks
            // against it before writing.
            phone.value = try connection.stat(file.path)
            let copy = folder.appendingPathComponent(file.name)
            try connection.pull(file.path, to: copy) { moved($0); return !cancel.isCancelled }
            return copy
        }
        job.onFinish = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let copy?):
                opened(session.id, copy: copy, phone: phone.value)
            case .success(nil):
                state.updateEditing(session.id) { $0.status = .failed("The file didn't arrive.") }
            case .failure(let error):
                state.updateEditing(session.id) { $0.status = .failed(error.localizedDescription) }
            }
        }
        queue.append(job)
        startNext()
    }

    func stopEditing(_ id: UUID) {
        watches[id] = nil
        state.editing.removeAll { $0.id == id }
        if watches.isEmpty {
            watcher?.invalidate()
            watcher = nil
        }
    }

    private func opened(_ id: UUID, copy: URL, phone: ADBSync.Entry?) {
        let values = try? copy.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        watches[id] = Watch(modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0,
                            phoneModified: phone?.modified ?? 0, phoneSize: phone?.size ?? 0)
        state.updateEditing(id) {
            $0.status = .editing
            $0.workingCopy = copy
        }
        openInApp(copy)
        if watcher == nil {
            watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkForSaves() }
            }
        }
    }

    /// Looks at every working copy once a second. Comparing the date and
    /// size of the file at its path catches every way apps save — writing
    /// in place, or writing a new file and swapping it in.
    func checkForSaves() {
        for (id, var watch) in watches {
            guard let copy = state.editing.first(where: { $0.id == id })?.workingCopy,
                  let values = try? copy.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate
            else { continue } // Mid-swap, the file can be missing for a moment.

            let size = values.fileSize ?? 0
            if modified != watch.modified || size != watch.size {
                watch.modified = modified
                watch.size = size
                watch.changedAt = Date()
            } else if let changedAt = watch.changedAt, Date().timeIntervalSince(changedAt) >= 1 {
                watch.changedAt = nil
                if watch.saving {
                    watch.saveAgain = true
                } else {
                    watch.saving = true
                    save(id, copy: copy, expecting: watch)
                }
            }
            watches[id] = watch
        }
    }

    private func save(_ id: UUID, copy: URL, expecting watch: Watch) {
        guard let session = state.editing.first(where: { $0.id == id }) else { return }
        state.updateEditing(id) { $0.status = .saving }

        let path = session.phonePath
        let outcome = Box<(path: String, beside: Bool, phone: ADBSync.Entry?)?>(nil)
        let transferID = UUID()
        state.transfers.append(FileTransfer(id: transferID, name: session.name, direction: .toPhone,
                                            bytesTotal: UInt64(max(watch.size, 0))))
        var job = Job(id: transferID, direction: .toPhone) { connection, cancel, _, moved in
            var target = path
            var beside = false
            if let current = try connection.stat(path),
               current.modified != watch.phoneModified || current.size != watch.phoneSize {
                // Someone changed the phone's copy since it was opened here:
                // keep theirs, and put this one beside it.
                target = try Self.unused(Self.besideName(for: path), connection)
                beside = true
            }
            try connection.push(copy, to: target) { moved($0); return !cancel.isCancelled }
            outcome.value = (target, beside, try connection.stat(target))
            return nil
        }
        job.onFinish = { [weak self] result in
            guard let self, var watch = watches[id] else { return }
            watch.saving = false
            switch result {
            case .success:
                if let saved = outcome.value {
                    watch.phoneModified = saved.phone?.modified ?? watch.phoneModified
                    watch.phoneSize = saved.phone?.size ?? watch.phoneSize
                    state.updateEditing(id) {
                        $0.phonePath = saved.path
                        $0.status = saved.beside ? .savedBeside((saved.path as NSString).lastPathComponent) : .saved(Date())
                    }
                }
            case .failure(let error):
                state.updateEditing(id) { $0.status = .failed(error.localizedDescription) }
            }
            let again = watch.saveAgain
            watch.saveAgain = false
            watches[id] = watch
            if again { watches[id]?.changedAt = Date.distantPast }
        }
        queue.append(job)
        startNext()
    }

    /// "Report.docx" becomes "Report (edited on Mac).docx".
    nonisolated static func besideName(for path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return "\(folder)/\(stem) (edited on Mac)\(ext.isEmpty ? "" : ".\(ext)")"
    }

    /// Working copies from sessions more than a week old. A copy may still
    /// be open in some app, so they are not removed when editing stops.
    nonisolated private static func clearOldWorkingCopies() {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: editingFolder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < weekAgo { try? manager.removeItem(at: folder) }
        }
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
            openInApp(url)
        }
        job.onFinish?(result)
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

/// A value handed out of a background job.
nonisolated final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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
