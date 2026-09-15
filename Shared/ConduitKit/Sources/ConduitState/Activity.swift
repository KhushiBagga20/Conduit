//
//  Activity.swift
//  ConduitState
//
//  The shared activity log. Entries describe what happened, never what was
//  in it: "Clipboard synced from phone", not the clipboard text.
//

import Foundation

public nonisolated struct ActivityEvent: Identifiable, Sendable, Equatable {

    public enum Kind: String, Sendable {
        case phoneConnected
        case phoneDisconnected
        case mirroringStarted
        case mirroringStopped
        case reconnecting
        case clipboardSynced
        case linkReceived
        case callReceived
        case cameraStarted
        case transferCompleted
        case permissionRequired
        case error
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let title: String
    public let detail: String?

    public init(kind: Kind, title: String, detail: String? = nil, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public var isError: Bool { kind == .error }
}
