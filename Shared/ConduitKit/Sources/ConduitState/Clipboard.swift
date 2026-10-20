//
//  Clipboard.swift
//  ConduitState
//
//  What the interfaces show about clipboard sync: which ways it can flow
//  right now, and what macOS allows. Never the clipboard itself.
//

import Foundation
import Observation

/// Whether macOS lets Conduit read this Mac's clipboard by itself.
public nonisolated enum MacClipboardAccess: Sendable, Equatable {
    /// Set to Always Allow — or a macOS without the question.
    case allowed
    /// macOS asks on every read, so Conduit does not read on its own.
    case asks
    /// The person chose Always Deny.
    case denied
}

@Observable
public final class ClipboardState {

    public package(set) var macAccess: MacClipboardAccess = .asks

    /// Copies on the phone arrive here by themselves: adb is connected, or a
    /// mirroring session is carrying them.
    public package(set) var phoneToMacAutomatic = false

    /// Some way to reach the phone exists: Conduit Link, adb or mirroring.
    public package(set) var canReachPhone = false

    package init() {}
}
