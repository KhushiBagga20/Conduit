//
//  PhoneSummary.swift
//  Conduit
//
//  The phone at a glance — name, status and how it is attached. The menu
//  bar uses the compact form; the workspace overview uses the large one.
//

import ConduitDesign
import ConduitState
import SwiftUI

struct PhoneSummary: View {
    enum Size { case compact, large }

    let phone: PhoneDevice
    var size: Size = .compact

    var body: some View {
        HStack(spacing: size == .large ? DesignTokens.Spacing.l : DesignTokens.Spacing.m) {
            PhoneGlyph(tone: phone.statusTone, size: size == .large ? 64 : 38)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(phone.name)
                    .font(size == .large ? DesignTokens.Typography.display.font : DesignTokens.Typography.headline.font)
                    .lineLimit(1)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    StatusDot(phone.statusTone, size: 7)
                    Text(phone.statusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .font(size == .large ? DesignTokens.Typography.body.font : DesignTokens.Typography.callout.font)

                if size == .large, !phone.detailLine.isEmpty {
                    Text(phone.detailLine)
                        .font(DesignTokens.Typography.callout.font)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A phone silhouette with a status ring — Conduit's device mark.
struct PhoneGlyph: View {
    let tone: StatusTone
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(
                    colors: [DesignTokens.Color.accent.color.opacity(0.18), DesignTokens.Color.flow.color.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "smartphone")
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(DesignTokens.Color.accent.color)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(tone.color)
                .frame(width: size * 0.26, height: size * 0.26)
                .overlay(Circle().strokeBorder(.background, lineWidth: max(1.5, size * 0.04)))
                .offset(x: size * 0.04, y: size * 0.04)
        }
        .accessibilityHidden(true)
    }
}

/// Shown wherever a phone is expected but none is available.
struct NoPhoneMessage: View {
    let tools: ToolStatus
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text(title)
                .font(compact ? DesignTokens.Typography.headline.font : DesignTokens.Typography.title.font)
            Text(message)
                .font(compact ? DesignTokens.Typography.callout.font : DesignTokens.Typography.body.font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        if case .missing = tools.adb { return "adb isn't installed" }
        return "No phone connected"
    }

    private var message: String {
        if case .missing = tools.adb {
            return "Conduit uses Android's debugging bridge to reach your phone. Install it with Homebrew: brew install android-platform-tools"
        }
        return "Plug in your phone with USB debugging on, or turn on Wireless debugging. Conduit finds it automatically."
    }
}
