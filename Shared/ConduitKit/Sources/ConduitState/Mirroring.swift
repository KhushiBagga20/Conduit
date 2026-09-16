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
    /// Hold the phone awake for the session — over USB and over Wi-Fi.
    public var stayAwake: Bool = true
    /// 1024 px at 4 Mbps. Fewer pixels help far more than a lower bitrate
    /// on a jittery Wi-Fi link.
    public var lowLatency: Bool = false
    /// Over Wi-Fi, cap the picture at `wifiMaxSize`. MEASURED: the test
    /// network's round trip swung between 8 and 85 ms; fewer pixels to encode,
    /// send and decode is what keeps a wireless session responsive.
    public var adaptToWiFi: Bool = true

    public static let wifiMaxSize = 1280

    public init() {}

    public var effectiveMaxSize: Int { lowLatency ? 1024 : maxSize }
    public var effectiveBitRate: Int { lowLatency ? 4_000_000 : bitRate }

    /// The longest edge to request for a session over `transport`.
    public func maxSize(over transport: PhoneTransport) -> Int {
        guard transport == .wifi, adaptToWiFi else { return effectiveMaxSize }
        return min(effectiveMaxSize, Self.wifiMaxSize)
    }

    // Decoding tolerates settings saved by older builds that lack newer keys.
    private enum CodingKeys: String, CodingKey {
        case maxSize, bitRate, maxFPS, audio, stayAwake, lowLatency, adaptToWiFi
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MirroringOptions()
        maxSize = try c.decodeIfPresent(Int.self, forKey: .maxSize) ?? defaults.maxSize
        bitRate = try c.decodeIfPresent(Int.self, forKey: .bitRate) ?? defaults.bitRate
        maxFPS = try c.decodeIfPresent(Int.self, forKey: .maxFPS) ?? defaults.maxFPS
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? defaults.audio
        stayAwake = try c.decodeIfPresent(Bool.self, forKey: .stayAwake) ?? defaults.stayAwake
        lowLatency = try c.decodeIfPresent(Bool.self, forKey: .lowLatency) ?? defaults.lowLatency
        adaptToWiFi = try c.decodeIfPresent(Bool.self, forKey: .adaptToWiFi) ?? defaults.adaptToWiFi
    }
}

public nonisolated enum MirroringStatus: Sendable, Equatable {
    case idle
    case starting
    case connecting
    case running
    case reconnecting(attempt: Int)
    /// The phone disappeared mid-session; mirroring resumes when it is back.
    case waitingForPhone
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .idle, .failed: false
        default: true
        }
    }
}

/// Whether touches on the phone's own screen are ignored while it is off.
public nonisolated enum TouchGuardStatus: Sendable, Equatable {
    case off
    case starting
    /// Touches on the phone are ignored; the Mac keeps control.
    case active
    /// Touches on the phone still work; the text says why.
    case unavailable(String)
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

    /// True while the phone is unreachable mid-session. The session is kept
    /// and resumes by itself when the phone returns over USB or Wi-Fi.
    public package(set) var isWaitingForPhone = false

    /// True while the phone's own screen is off and mirroring continues.
    public package(set) var isPhoneScreenOff = false

    /// Whether the phone ignores its own touchscreen while its screen is off.
    public package(set) var touchGuard: TouchGuardStatus = .off

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
            if isWaitingForPhone { return .waitingForPhone }
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
