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

    package init() {}

    package func update(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }
}
