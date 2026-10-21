//
//  Files.swift
//  ConduitState
//
//  What the Files page shows: the phone folder open now, and the files
//  moving each way.
//

import Foundation
import Observation

/// One item in a phone folder.
public nonisolated struct PhoneFile: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isFolder: Bool
    public let size: UInt64
    public let modified: Date

    public init(path: String, name: String, isFolder: Bool, size: UInt64, modified: Date) {
        self.path = path
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
    }
}

/// A file — or a folder of them — on its way to this Mac or to the phone.
public nonisolated struct FileTransfer: Identifiable, Sendable, Equatable {
    public enum Direction: Sendable, Equatable { case toMac, toPhone }
    public enum Status: Sendable, Equatable {
        case waiting, moving, done, cancelled
        case failed(String)
    }

    public let id: UUID
    public let name: String
    public let direction: Direction
    public package(set) var bytesDone: UInt64
    public package(set) var bytesTotal: UInt64
    public package(set) var status: Status
    /// Where a finished download landed, for Show in Finder.
    public package(set) var savedTo: URL?

    package init(id: UUID = UUID(), name: String, direction: Direction, bytesTotal: UInt64) {
        self.id = id
        self.name = name
        self.direction = direction
        self.bytesDone = 0
        self.bytesTotal = bytesTotal
        self.status = .waiting
    }

    public var isFinished: Bool {
        switch status {
        case .done, .cancelled, .failed: true
        case .waiting, .moving: false
        }
    }
}

/// A phone file open in a Mac app. Saving it there writes it back to the
/// phone.
public nonisolated struct EditSession: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case opening
        case editing
        case saving
        case saved(Date)
        /// The phone's own copy changed after it was opened here, so this
        /// save went beside it under another name rather than over it.
        case savedBeside(String)
        case failed(String)
    }

    public let id: UUID
    public let name: String
    /// Where saves go on the phone. It moves to the copy beside the
    /// original after a conflict, so later saves keep going there.
    public package(set) var phonePath: String
    public package(set) var status: Status
    /// The copy on this Mac that the app has open.
    public package(set) var workingCopy: URL?

    package init(id: UUID = UUID(), name: String, phonePath: String) {
        self.id = id
        self.name = name
        self.phonePath = phonePath
        self.status = .opening
    }
}

@Observable
public final class FilesState {

    /// The phone's shared storage — what Android's own Files app calls
    /// internal storage.
    public static let root = "/storage/emulated/0"

    /// adb reaches the phone, so its files can be browsed.
    public package(set) var isAvailable = false
    public package(set) var folder = FilesState.root
    public package(set) var entries: [PhoneFile] = []
    public package(set) var isLoading = false
    public package(set) var error: String?
    public package(set) var transfers: [FileTransfer] = []
    public package(set) var editing: [EditSession] = []

    package init() {}

    package func update(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    package func updateEditing(_ id: UUID, _ change: (inout EditSession) -> Void) {
        guard let index = editing.firstIndex(where: { $0.id == id }) else { return }
        change(&editing[index])
    }
}
