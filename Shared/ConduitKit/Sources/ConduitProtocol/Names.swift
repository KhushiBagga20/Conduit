//
//  Names.swift
//  ConduitProtocol
//
//  Action, event, feature and error identifiers — the vocabulary shared by
//  every Conduit interface. Spec: Shared/Protocol/README.md §6 and §8.
//
//  Names are open sets: a newer peer may send one this build does not know,
//  and it must round-trip intact rather than fail to decode.
//

import Foundation

// MARK: - Actions

public struct ActionName: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let sessionPing = ActionName("session.ping")
    public static let stateSync = ActionName("state.sync")
    public static let mirroringRequest = ActionName("mirroring.request")
    public static let trackpadStart = ActionName("trackpad.start")
    public static let trackpadStop = ActionName("trackpad.stop")
    public static let linkSend = ActionName("link.send")
    public static let clipboardSet = ActionName("clipboard.set")
    public static let callAnswer = ActionName("call.answer")
    public static let callDecline = ActionName("call.decline")
    public static let callEnd = ActionName("call.end")
    public static let callDial = ActionName("call.dial")
    public static let callMute = ActionName("call.mute")
    public static let macFind = ActionName("mac.find")
}

// MARK: - Events

public struct EventName: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let sessionBye = EventName("session.bye")
    public static let deviceSnapshot = EventName("device.snapshot")
    public static let deviceBattery = EventName("device.battery")
    public static let deviceNetwork = EventName("device.network")
    public static let deviceLock = EventName("device.lock")
    public static let featuresChanged = EventName("features.changed")
    public static let trackpadState = EventName("trackpad.state")
    public static let trackpadConfig = EventName("trackpad.config")
    public static let callIncoming = EventName("call.incoming")
    public static let callState = EventName("call.state")
}

// MARK: - Features

public enum FeatureID: String, CaseIterable, Codable, Sendable {
    case mirroring
    case remoteInput
    case trackpad
    case clipboard
    case camera
    case calls
    case links
    case audio
    case files
    case notifications
    case findMac
}

public enum Availability: String, Codable, Sendable {
    case available
    case active
    case requiresPermission = "requires_permission"
    case requiresSetup = "requires_setup"
    case disabled
    case unsupported
    case planned

    /// True when the user can use the feature right now.
    public var isUsable: Bool { self == .available || self == .active }
}

// MARK: - Errors

public struct ErrorCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let invalidRequest = ErrorCode("invalid_request")
    public static let unsupported = ErrorCode("unsupported")
    public static let permissionDenied = ErrorCode("permission_denied")
    public static let requiresSetup = ErrorCode("requires_setup")
    public static let deviceUnavailable = ErrorCode("device_unavailable")
    public static let phoneLocked = ErrorCode("phone_locked")
    public static let timeout = ErrorCode("timeout")
    public static let networkChanged = ErrorCode("network_changed")
    public static let peerRestarted = ErrorCode("peer_restarted")
    public static let duplicateRequest = ErrorCode("duplicate_request")
    public static let staleEvent = ErrorCode("stale_event")
    public static let notPaired = ErrorCode("not_paired")
    public static let versionMismatch = ErrorCode("version_mismatch")
    public static let busy = ErrorCode("busy")
    public static let cancelled = ErrorCode("cancelled")
    public static let `internal` = ErrorCode("internal")

    static let known: Set<ErrorCode> = [
        .invalidRequest, .unsupported, .permissionDenied, .requiresSetup, .deviceUnavailable,
        .phoneLocked, .timeout, .networkChanged, .peerRestarted, .duplicateRequest, .staleEvent,
        .notPaired, .versionMismatch, .busy, .cancelled, .internal,
    ]

    /// Spec §8: a code this build does not know is handled as `internal`.
    public var normalized: ErrorCode { Self.known.contains(self) ? self : .internal }
}

public struct ProtocolError: Error, Codable, Sendable, Equatable {
    public var code: ErrorCode
    /// Human-readable and safe to show to the user.
    public var message: String

    public init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
