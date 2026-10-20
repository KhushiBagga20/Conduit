//
//  PhoneSummary.swift
//  Conduit
//
//  The phone as the Mac shows it: an icon in the style of System Settings'
//  account row, its name and its status.
//

import ConduitDesign
import ConduitState
import SwiftUI

/// A device icon in the Mac's own manner: a black tile with a glassy sheen
/// across the top, the phone's glyph, and a status badge.
struct DeviceIcon: View {
    var tone: StatusTone?
    var size: CGFloat = 40

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        tile
            .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.03)], startPoint: .top, endPoint: .bottom))
            .overlay(tile.fill(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .center)))
            .overlay(tile.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "smartphone")
                    .font(.system(size: size * 0.48, weight: .medium))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) {
                if let tone {
                    Circle()
                        .fill(tone.color)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: max(1.5, size * 0.05)))
                        .offset(x: size * 0.08, y: size * 0.08)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// Name and status, for list rows and headers.
struct PhoneTitle: View {
    let phone: PhoneDevice
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 3 : 1) {
            Text(phone.name)
                .font(large ? .title2.weight(.semibold) : .headline)
                .lineLimit(1)
            HStack(spacing: 5) {
                StatusDot(phone.statusTone, size: large ? 8 : 7)
                Text(statusLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(large ? .body : .subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        phone.connection.isConnected ? "Connected over \(phone.transportSummary)" : phone.statusText
    }
}

/// The message shown wherever a phone is expected and none is available.
struct NoPhoneView: View {
    let tools: ToolStatus

    var body: some View {
        if case .missing = tools.adb {
            ContentUnavailableView {
                Label("adb Isn't Installed", systemImage: "wrench.and.screwdriver")
            } description: {
                Text("Conduit uses Android's debugging bridge to reach your phone. Install it with Homebrew:\nbrew install android-platform-tools")
            }
        } else {
            ContentUnavailableView {
                Label("No Phone Connected", systemImage: "smartphone")
            } description: {
                Text("Connect your phone with USB debugging on, or turn on Wireless debugging. Conduit finds it automatically.")
            }
        }
    }
}
