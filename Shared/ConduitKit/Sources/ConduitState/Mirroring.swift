//
//  Mirroring.swift
//  ConduitState
//
//  The state of the phone-screen session, observed by every interface.
//

import ConduitMedia
import Foundation
import Observation

public nonisolated struct MirroringOptions: Codable, Sendable, Equatable {
    /// Longest edge in pixels.
    public var maxSize: Int = 1920
    public var bitRate: Int = 2_000_000
    public var maxFPS: Int = 60
    /// Forward the phone's audio to the Mac while mirroring.
    public var audio: Bool = true
    /// Hold the phone awake for the session.
    public var stayAwake: Bool = true
    /// 1024 px at 4 Mbps. Fewer pixels help far more than a lower bitrate
    /// on a jittery Wi-Fi link.
    public var lowLatency: Bool = false

    public init() {}

    public var effectiveMaxSize: Int { lowLatency ? 1024 : maxSize }
    public var effectiveBitRate: Int { lowLatency ? 4_000_000 : bitRate }
}

public nonisolated enum MirroringStatus: Sendable, Equatable {
    case idle
    case starting
    case connecting
    case running
    case reconnecting(attempt: Int)
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .idle, .failed: false
        default: true
        }
    }
}

@Observable
public final class MirroringState {

    /// The phone being mirrored.
    public package(set) var phoneID: String?

    /// Lifecycle as seen by the owner: nil while idle.
    public package(set) var phase: Phase = .idle

    /// The live media session — the phone screen view renders its renderer
    /// and sends input through it. Nil unless mirroring is active.
    public package(set) var session: MirroringSession?

    /// The transport the current server runs over.
    public package(set) var transport: PhoneTransport?

    public enum Phase: Sendable, Equatable {
        case idle
        case startingServer
        case active
        case failed(String)
    }

    package init() {}

    /// One status for every interface, combining the owner's phase with the
    /// media session's own sockets and reconnect state.
    public var status: MirroringStatus {
        switch phase {
        case .idle:
            return .idle
        case .startingServer:
            return .starting
        case .failed(let message):
            return .failed(message)
        case .active:
            guard let session else { return .starting }
            if session.isReconnecting { return .reconnecting(attempt: session.reconnectAttempt) }
            switch session.stream.state {
            case .connected: return session.stream.decodedFrameCount > 0 ? .running : .connecting
            case .connecting, .disconnected: return .connecting
            case .failed: return .reconnecting(attempt: max(session.reconnectAttempt, 1))
            }
        }
    }
}
