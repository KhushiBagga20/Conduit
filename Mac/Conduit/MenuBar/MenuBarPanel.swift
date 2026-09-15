//
//  MenuBarPanel.swift
//  Conduit
//
//  The always-available layer, built like Control Center: a device header,
//  a grid of toggles that each do something real, and menu rows below.
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
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            deviceHeader
            controls
            actions
            if !store.activity.isEmpty {
                recent
            }
            MenuDivider()
            MenuRow("Conduit Settings…") { showSettings() }
            MenuRow("Quit Conduit") {
                AppDelegate.quitRequested = true
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 320)
    }

    // MARK: - Device

    @ViewBuilder
    private var deviceHeader: some View {
        PanelModule {
            if let phone = store.activePhone {
                HStack(spacing: 10) {
                    DeviceIcon(tone: phone.statusTone, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phone.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(phone.connection.isConnected ? "Connected over \(phone.transportSummary)" : phone.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if store.connectedPhones.count > 1 {
                        Menu {
                            ForEach(store.connectedPhones) { other in
                                Button(other.name) { store.commands?.selectPhone(other.id) }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose a phone")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    DeviceIcon(tone: .idle, size: 36)
                        .saturation(0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(missingADB ? "adb isn't installed" : "No phone connected")
                            .font(.system(size: 13, weight: .semibold))
                        Text(missingADB ? "brew install android-platform-tools" : "Connect over USB or Wireless debugging")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var missingADB: Bool {
        if case .missing = store.tools.adb { return true }
        return false
    }

    // MARK: - Controls

    private var controls: some View {
        let phone = store.activePhone
        let status = store.mirroring.status
        let controlReady = store.mirroring.session?.control.state == .connected
        let canMirror = phone?.availability(.mirroring).isUsable == true

        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                ControlToggle(
                    title: "Mirroring",
                    subtitle: mirroringSubtitle(status),
                    systemImage: "rectangle.on.rectangle",
                    isOn: status.isActive,
                    isEnabled: status.isActive || canMirror
                ) {
                    if status.isActive {
                        store.commands?.stopMirroring()
                    } else {
                        store.commands?.startMirroring(phoneID: phone?.id)
                        open(.phoneScreen)
                    }
                }

                ControlToggle(
                    title: "Phone Screen",
                    subtitle: !controlReady ? "While mirroring" : (store.mirroring.isPhoneScreenOff ? "Off" : "On"),
                    systemImage: store.mirroring.isPhoneScreenOff ? "rectangle.portrait.slash" : "rectangle.portrait",
                    isOn: store.mirroring.isPhoneScreenOff,
                    isEnabled: controlReady
                ) {
                    store.commands?.setPhoneScreen(on: store.mirroring.isPhoneScreenOff)
                }
            }
            GridRow {
                ControlToggle(
                    title: "Clipboard",
                    subtitle: store.preferences.clipboardSync ? "Sync on" : "Sync off",
                    systemImage: "doc.on.clipboard",
                    isOn: store.preferences.clipboardSync,
                    isEnabled: true
                ) {
                    let enabled = !store.preferences.clipboardSync
                    store.commands?.updatePreferences { $0.clipboardSync = enabled }
                }

                ControlToggle(
                    title: "Wi-Fi",
                    subtitle: store.preferences.autoConnectWireless ? "Reconnect on" : "Reconnect off",
                    systemImage: "wifi",
                    isOn: store.preferences.autoConnectWireless,
                    isEnabled: true
                ) {
                    let enabled = !store.preferences.autoConnectWireless
                    store.commands?.updatePreferences { $0.autoConnectWireless = enabled }
                }
            }
        }
    }

    private func mirroringSubtitle(_ status: MirroringStatus) -> String {
        switch status {
        case .running: store.mirroring.transport == .wifi ? "On · Wi-Fi" : "On · USB"
        case .failed: "Stopped"
        default: status.text
        }
    }

    // MARK: - Actions

    private var actions: some View {
        let status = store.mirroring.status
        let controlReady = store.mirroring.session?.control.state == .connected
        let phone = store.activePhone

        return VStack(alignment: .leading, spacing: 0) {
            MenuDivider()
            MenuRow("Open Conduit", systemImage: "macwindow") { open(router.section) }
            if status.isActive {
                MenuRow("Show Phone Screen", systemImage: "rectangle.on.rectangle") { open(.phoneScreen) }
            }
            if case .failed = status {
                MenuRow("Try Mirroring Again", systemImage: "arrow.clockwise") { store.commands?.restartMirroring() }
            }
            MenuRow("Send Clipboard", systemImage: "doc.on.clipboard",
                    trailing: controlReady ? nil : "While mirroring", isEnabled: controlReady) {
                store.commands?.sendMacClipboardToPhone()
            }

            MenuSectionHeader("Coming to Conduit")
            ForEach(plannedActions, id: \.title) { action in
                MenuRow(action.title, systemImage: action.symbol,
                        trailing: (phone?.availability(action.feature) ?? .planned).label, isEnabled: false) {}
            }
        }
    }

    private var plannedActions: [(title: String, symbol: String, feature: FeatureID)] {
        [
            ("Use Phone as Trackpad", "hand.point.up.left", .trackpad),
            ("Use Phone Camera", "camera", .camera),
            ("Share Link", "link", .links),
            ("Call from Phone", "phone", .calls),
            ("Find My Mac", "laptopcomputer", .findMac),
        ]
    }

    // MARK: - Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuDivider()
            MenuSectionHeader("Recent")
            ForEach(store.activity.prefix(3)) { event in
                HStack(spacing: 8) {
                    Image(systemName: event.symbol)
                        .foregroundStyle(event.tone.color)
                        .frame(width: 16)
                    Text(event.title)
                        .lineLimit(1)
                    Spacer()
                    Text(event.date, format: .dateTime.hour().minute())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Windows

    private func open(_ section: WorkspaceRouter.Section) {
        router.section = section
        openWindow(id: WorkspaceRouter.windowID)
        AppPresentation.windowOpened()
    }

    private func showSettings() {
        AppPresentation.windowOpened()
        openSettings()
    }
}

// MARK: - Control Center pieces

/// A translucent rounded module, as Control Center groups its controls.
struct PanelModule<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ModuleBackground())
    }
}

private struct ModuleBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

/// A Control Center toggle: a circle that fills with the accent colour when
/// on, a title and a one-line state.
struct ControlToggle: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ModuleBackground())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(subtitle)
    }
}

/// A row that highlights on hover, like an item in a menu.
struct MenuRow: View {
    let title: String
    var systemImage: String?
    var trailing: String?
    var isEnabled = true
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, systemImage: String? = nil, trailing: String? = nil,
         isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        let highlighted = hovering && isEnabled

        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 16)
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
                Text(title)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : (isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(highlighted ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
    }
}

struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 4)
    }
}
