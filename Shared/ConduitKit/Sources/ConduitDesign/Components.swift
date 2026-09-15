//
//  Components.swift
//  ConduitDesign
//
//  Small building blocks every Mac surface uses, so status, availability and
//  cards look the same in the menu bar and in the workspace.
//

import ConduitProtocol
import SwiftUI

// MARK: - Status

/// The four states every connection-shaped thing in Conduit can be in.
public enum StatusTone: Sendable {
    case connected, working, error, idle

    public var color: Color {
        switch self {
        case .connected: DesignTokens.Color.statusConnected.color
        case .working: DesignTokens.Color.statusWorking.color
        case .error: DesignTokens.Color.statusError.color
        case .idle: DesignTokens.Color.statusIdle.color
        }
    }
}

/// A status dot. While working it breathes, so "in progress" never reads as
/// "stuck".
public struct StatusDot: View {
    private let tone: StatusTone
    private let size: CGFloat
    @State private var pulsing = false

    public init(_ tone: StatusTone, size: CGFloat = 8) {
        self.tone = tone
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
            .opacity(tone == .working && pulsing ? 0.35 : 1)
            .animation(tone == .working
                       ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                       : .default, value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Availability

/// A label for a feature that is not simply available: Planned, Requires
/// permission, Needs setup, Not supported on this device. Nothing in Conduit
/// shows a button for a feature that cannot work without saying why.
public struct AvailabilityBadge: View {
    private let availability: Availability

    public init(_ availability: Availability) {
        self.availability = availability
    }

    public var body: some View {
        Text(DesignTokens.availabilityLabel[availability.rawValue] ?? availability.rawValue)
            .font(DesignTokens.Typography.caption.font.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, DesignTokens.Spacing.s)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(foreground.opacity(0.12), in: Capsule())
    }

    private var foreground: Color {
        switch availability {
        case .available, .active: DesignTokens.Color.statusConnected.color
        case .requiresPermission, .requiresSetup: DesignTokens.Color.statusWorking.color
        case .unsupported: DesignTokens.Color.statusError.color
        case .disabled, .planned: DesignTokens.Color.textTertiary.color
        }
    }
}

// MARK: - Card

public extension View {
    /// Conduit's card surface: a quiet fill and a hairline border on a
    /// continuous-corner rectangle. Cards always span their container, so a
    /// short message never sits in a card narrower than its neighbours.
    func conduitCard(padding: CGFloat = DesignTokens.Spacing.l) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(DesignTokens.Color.surface.color,
                        in: RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                    .strokeBorder(DesignTokens.Color.border.color, lineWidth: 1))
    }
}
