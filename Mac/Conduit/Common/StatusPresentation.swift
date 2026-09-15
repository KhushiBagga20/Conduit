//
//  StatusPresentation.swift
//  Conduit
//
//  One vocabulary for status, used by the menu bar and the workspace alike.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import Foundation

extension PhoneDevice {
    var statusTone: StatusTone {
        switch connection {
        case .connected: .connected
        case .unauthorized, .offline: .working
        case .disconnected: .idle
        }
    }

    var statusText: String {
        switch connection {
        case .connected(.usb): "Connected over USB"
        case .connected(.wifi): "Connected over Wi-Fi"
        case .unauthorized: "Allow debugging on the phone"
        case .offline: DesignTokens.Term.reconnecting
        case .disconnected:
            lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" }
                ?? DesignTokens.Term.notConnected
        }
    }

    var transportSummary: String {
        let names = transports.sorted().map { $0 == .usb ? "USB" : "Wi-Fi" }
        return names.isEmpty ? "—" : names.joined(separator: " + ")
    }

    func availability(_ feature: FeatureID) -> Availability {
        features[feature] ?? .planned
    }
}

extension MirroringStatus {
    var tone: StatusTone {
        switch self {
        case .running: .connected
        case .starting, .connecting, .reconnecting: .working
        case .failed: .error
        case .idle: .idle
        }
    }

    var text: String {
        switch self {
        case .idle: "Not mirroring"
        case .starting: "Starting the screen server…"
        case .connecting: "Connecting to the phone screen…"
        case .running: "Mirroring"
        case .reconnecting(let attempt): attempt > 1 ? "Reconnecting… (attempt \(attempt))" : "Reconnecting…"
        case .failed(let message): message
        }
    }
}

extension ActivityEvent {
    var symbol: String {
        switch kind {
        case .phoneConnected: "smartphone"
        case .phoneDisconnected: "bolt.horizontal"
        case .mirroringStarted: "rectangle.on.rectangle"
        case .mirroringStopped: "stop.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .clipboardSynced: "doc.on.clipboard"
        case .linkReceived: "link"
        case .callReceived: "phone"
        case .cameraStarted: "camera"
        case .transferCompleted: "doc"
        case .permissionRequired: "lock.shield"
        case .error: "exclamationmark.triangle"
        }
    }

    var tone: StatusTone {
        switch kind {
        case .error: .error
        case .permissionRequired, .reconnecting: .working
        case .phoneDisconnected, .mirroringStopped: .idle
        default: .connected
        }
    }
}

extension FeatureID {
    var title: String {
        DesignTokens.Feature.all.first { $0.id == rawValue }?.title ?? rawValue
    }

    var symbol: String {
        DesignTokens.Feature.all.first { $0.id == rawValue }?.symbol ?? "circle"
    }

    /// What it will take, for features that are not available yet.
    var plannedDetail: String {
        switch self {
        case .trackpad: "Turns the phone into a trackpad for this Mac. Arrives with Conduit for Android."
        case .camera: "Shows the phone's camera inside Conduit, front or back. Needs Android 12."
        case .calls: "Answer, decline and place calls from the Mac. Arrives with Conduit for Android; call audio stays on the phone."
        case .links: "Send a link from the Mac to the phone and back. Arrives with Conduit for Android."
        case .files: "Send files between the Mac and the phone."
        case .notifications: "See the phone's notifications on the Mac."
        case .findMac: "Ring this Mac from the phone. Arrives with Conduit for Android."
        case .mirroring, .remoteInput, .clipboard, .audio: "Works over USB or Wireless debugging."
        }
    }
}
