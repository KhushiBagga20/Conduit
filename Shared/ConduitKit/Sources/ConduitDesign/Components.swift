//
//  Components.swift
//  ConduitDesign
//
//  Small building blocks every Mac surface uses, so status looks the same in
//  the menu bar and in the workspace.
//

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
