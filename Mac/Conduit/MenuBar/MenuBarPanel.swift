//
//  MenuBarPanel.swift
//  Conduit
//
//  The always-available layer: is the phone here, what is it doing, and the
//  handful of things worth doing without opening the workspace.
//
//  Kept deliberately small. Anything that needs more than a glance or a
//  click belongs in the workspace.
//

import AppKit
import ConduitDesign
import ConduitMedia
import ConduitProtocol
import ConduitState
import SwiftUI

struct MenuBarPanel: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            header

            phoneSection
                .conduitCard(padding: DesignTokens.Spacing.m)

            if store.mirroring.status != .idle {
                mirroringRow
            }

            quickActions

            if !store.activity.isEmpty {
                recentActivity
            }

            Divider()
            footer
        }
        .padding(DesignTokens.Spacing.l)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            ConduitMark(size: 22)
            Text(DesignTokens.Brand.name)
                .font(DesignTokens.Typography.headline.font)
            Spacer()
            Button {
                open(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Phone

    @ViewBuilder
    private var phoneSection: some View {
        if let phone = store.activePhone {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                PhoneSummary(phone: phone)
                if store.connectedPhones.count > 1 {
                    Picker("Phone", selection: Binding(
                        get: { store.activePhoneID ?? phone.id },
                        set: { store.commands?.selectPhone($0) })) {
                        ForEach(store.connectedPhones) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        } else {
            NoPhoneMessage(tools: store.tools, compact: true)
        }
    }

    // MARK: - Mirroring

    private var mirroringRow: some View {
        let status = store.mirroring.status
        return HStack(spacing: DesignTokens.Spacing.s) {
            StatusDot(status.tone, size: 7)
            Text(status.text)
                .font(DesignTokens.Typography.callout.font)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if case .failed = status {
                Button("Try Again") { store.commands?.restartMirroring() }
                    .controlSize(.small)
            } else {
                Button("Stop") { store.commands?.stopMirroring() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        let phone = store.activePhone
        let mirroring = store.mirroring.status.isActive
        let controlReady = store.mirroring.session?.control.state == .connected

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.s), count: 3),
                         spacing: DesignTokens.Spacing.s) {
            QuickActionTile(
                title: mirroring ? "Show Screen" : DesignTokens.Term.mirrorScreen,
                symbol: "rectangle.on.rectangle",
                availability: phone?.availability(.mirroring) ?? .requiresSetup) {
                open(.phoneScreen)
                if !mirroring { store.commands?.startMirroring(phoneID: phone?.id) }
            }

            QuickActionTile(
                title: DesignTokens.Term.sendClipboard,
                symbol: "doc.on.clipboard",
                availability: controlReady ? .available : .requiresSetup,
                unavailableLabel: "While mirroring") {
                store.commands?.sendMacClipboardToPhone()
            }

            QuickActionTile(title: "Trackpad", symbol: "hand.point.up.left",
                            availability: phone?.availability(.trackpad) ?? .planned) {}
            QuickActionTile(title: "Camera", symbol: "camera",
                            availability: phone?.availability(.camera) ?? .planned) {}
            QuickActionTile(title: DesignTokens.Term.shareLink, symbol: "link",
                            availability: phone?.availability(.links) ?? .planned) {}
            QuickActionTile(title: "Call", symbol: "phone",
                            availability: phone?.availability(.calls) ?? .planned) {}
        }
    }

    // MARK: - Activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Recent")
                .font(DesignTokens.Typography.caption.font.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(store.activity.prefix(3)) { event in
                HStack(spacing: DesignTokens.Spacing.s) {
                    Image(systemName: event.symbol)
                        .foregroundStyle(event.tone.color)
                        .frame(width: 16)
                    Text(event.title)
                        .lineLimit(1)
                    Spacer()
                    Text(event.date, style: .time)
                        .foregroundStyle(.tertiary)
                }
                .font(DesignTokens.Typography.callout.font)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Open Conduit") { open(router.section) }
                .keyboardShortcut("o")
            Spacer()
            Button("Quit Conduit") {
                AppDelegate.quitRequested = true
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(DesignTokens.Typography.callout.font)
    }

    private func open(_ section: WorkspaceRouter.Section) {
        router.section = section
        openWindow(id: WorkspaceRouter.windowID)
        AppPresentation.workspaceDidOpen()
    }
}

/// A square action button that says why it cannot be used, instead of
/// silently doing nothing.
struct QuickActionTile: View {
    let title: String
    let symbol: String
    let availability: Availability
    var unavailableLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                Text(title)
                    .font(DesignTokens.Typography.caption.font.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !availability.isUsable {
                    Text(unavailableLabel ?? DesignTokens.availabilityLabel[availability.rawValue] ?? "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickActionButtonStyle(enabled: availability.isUsable))
        .disabled(!availability.isUsable)
        .help(availability.isUsable ? title : "\(title) — \(unavailableLabel ?? DesignTokens.availabilityLabel[availability.rawValue] ?? "")")
    }
}

private struct QuickActionButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? AnyShapeStyle(DesignTokens.Color.accent.color) : AnyShapeStyle(.tertiary))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.medium, style: .continuous)
                    .fill(configuration.isPressed
                          ? DesignTokens.Color.accent.color.opacity(0.18)
                          : DesignTokens.Color.surfaceMuted.color.opacity(enabled ? 1 : 0.6)))
            .animation(.easeOut(duration: DesignTokens.Motion.quick), value: configuration.isPressed)
    }
}

/// Conduit's mark: two linked nodes on the accent gradient.
struct ConduitMark: View {
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: [DesignTokens.Color.accent.color, DesignTokens.Color.flow.color],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
