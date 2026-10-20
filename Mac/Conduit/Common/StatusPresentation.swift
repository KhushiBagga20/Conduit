//
//  StatusPresentation.swift
//  Conduit
//
//  One vocabulary for status, used by the menu bar and the workspace alike.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

extension ConduitStore {
    /// What a feature can offer now. Link sharing and find-my-Mac travel over
    /// Conduit Link, so they depend on a linked phone being connected rather
    /// than on adb.
    func availability(_ feature: FeatureID) -> Availability {
        switch feature {
        case .links, .findMac: link.hasConnectedPhone ? .available : .requiresSetup
        case .files: files.isAvailable ? .available : .requiresSetup
        case .notifications:
            if !link.hasConnectedPhone { .requiresSetup }
            else if !link.notificationsReady { .requiresPermission }
            else { .available }
        case .trackpad:
            if link.phones.isEmpty { .requiresSetup }
            else if !link.trackpadTrusted { .requiresPermission }
            else if !preferences.phoneTrackpad { .disabled }
            else { .available }
        default: activePhone?.availability(feature) ?? .planned
        }
    }
}

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
        case .connected: "Connected"
        case .unauthorized: "Allow debugging on the phone"
        case .offline: DesignTokens.Term.reconnecting
        case .disconnected:
            lastSeen.map { "Last seen \($0.formatted(.relative(presentation: .named)))" }
                ?? DesignTokens.Term.notConnected
        }
    }

    /// "USB", "Wi-Fi", or "USB and Wi-Fi".
    var transportSummary: String {
        let names = transports.sorted().map { $0 == .usb ? "USB" : "Wi-Fi" }
        return names.isEmpty ? "Not connected" : names.formatted(.list(type: .and))
    }

    var androidVersionText: String {
        osVersion.map { "Android \($0)" } ?? "—"
    }

    var modelText: String {
        [manufacturer?.capitalized, model].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "—"
    }

    func availability(_ feature: FeatureID) -> Availability {
        features[feature] ?? .planned
    }
}

extension MirroringStatus {
    var tone: StatusTone {
        switch self {
        case .running: .connected
        case .starting, .connecting, .reconnecting, .waitingForPhone: .working
        case .failed: .error
        case .idle: .idle
        }
    }

    var text: String {
        switch self {
        case .idle: "Off"
        case .starting: "Starting…"
        case .connecting: "Connecting…"
        case .running: "On"
        case .reconnecting(let attempt): attempt > 1 ? "Reconnecting (attempt \(attempt))…" : "Reconnecting…"
        case .waitingForPhone: "Waiting for the phone…"
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
        case .ringing: "wave.3.right"
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
        case .permissionRequired, .reconnecting, .ringing: .working
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

    /// What the feature does, and what it needs when it is not available.
    var detail: String {
        switch self {
        case .mirroring: "See the phone's screen on this Mac."
        case .remoteInput: "Control the phone with this Mac's mouse, trackpad and keyboard while mirroring."
        case .clipboard: "Copy on one device and paste on the other."
        case .audio: "Hear the phone on this Mac while mirroring. Needs Android 11."
        case .trackpad: "Turn the phone into a trackpad for this Mac. Needs macOS Accessibility permission."
        case .camera: "Use the phone's cameras inside Conduit. Needs Android 12."
        case .calls: "Answer, decline and place calls from this Mac. Call audio stays on the phone."
        case .links: "Send web links between this Mac and the phone over Conduit Link."
        case .files: "Browse the phone's storage, and move files and folders both ways, over USB or Wi-Fi."
        case .notifications: "See the phone's notifications on this Mac, and dismiss them from here."
        case .findMac: "Ring this Mac from the phone, over Conduit Link, when you cannot find it."
        }
    }
}

extension Availability {
    var label: String {
        DesignTokens.availabilityLabel[rawValue] ?? rawValue
    }

    var symbol: String {
        switch self {
        case .available, .active: "checkmark.circle.fill"
        case .requiresPermission, .requiresSetup: "exclamationmark.circle.fill"
        case .unsupported: "xmark.circle.fill"
        case .disabled: "minus.circle"
        case .planned: "clock"
        }
    }

    var tint: Color {
        switch self {
        case .available, .active: StatusTone.connected.color
        case .requiresPermission, .requiresSetup: StatusTone.working.color
        case .unsupported: StatusTone.error.color
        case .disabled, .planned: .secondary
        }
    }
}

/// Availability shown the way System Settings shows status: a tinted symbol
/// and a short secondary label.
struct AvailabilityLabel: View {
    let availability: Availability

    var body: some View {
        Label {
            Text(availability.label)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: availability.symbol)
                .foregroundStyle(availability.tint)
        }
        .labelStyle(.titleAndIcon)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
