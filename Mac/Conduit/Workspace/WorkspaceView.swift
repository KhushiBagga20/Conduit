//
//  WorkspaceView.swift
//  Conduit
//
//  The full Mac workspace: a standard source-list sidebar and one page per
//  section. Pages read ConduitStore and call ConduitCommands; none of them
//  owns a connection, so closing this window leaves the phone connected.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct WorkspaceView: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        NavigationSplitView {
            Sidebar(selection: $router.section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            page(for: router.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { AppPresentation.windowOpened() }
        .onDisappear { AppPresentation.windowClosed() }
    }

    @ViewBuilder
    private func page(for section: WorkspaceRouter.Section) -> some View {
        switch section {
        case .overview: OverviewPage()
        case .phoneScreen: PhoneScreenPage()
        case .clipboard: ClipboardPage()
        case .activity: ActivityPage()
        case .devices: DevicesPage()
        case .settings: SettingsForm().navigationTitle("Settings")
        case .links: LinksPage()
        case .trackpad, .camera, .calls:
            PlannedFeaturePage(section: section)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(ConduitStore.self) private var store
    @Binding var selection: WorkspaceRouter.Section

    var body: some View {
        List(selection: $selection) {
            Section("Phone") {
                row(.overview)
                row(.phoneScreen)
                row(.trackpad)
                row(.camera)
            }
            Section("Continuity") {
                row(.calls)
                row(.links)
                row(.clipboard)
            }
            Section("Conduit") {
                row(.activity)
                row(.devices)
                row(.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarPhoneStatus()
        }
    }

    @ViewBuilder
    private func row(_ section: WorkspaceRouter.Section) -> some View {
        let label = Label(section.title, systemImage: section.symbol).tag(section)

        if section == .phoneScreen, store.mirroring.status.isActive {
            label.badge(Text(store.mirroring.status == .running ? "Live" : "…"))
        } else if let feature = section.feature, store.availability(feature) == .planned {
            label.badge(Text("Planned"))
        } else {
            label
        }
    }
}

/// The phone at the foot of the sidebar, where Xcode shows its run
/// destination: always visible, whichever page is open.
private struct SidebarPhoneStatus: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                DeviceIcon(tone: store.activePhone?.statusTone ?? .idle, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(store.activePhone?.name ?? "No Phone")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        guard let phone = store.activePhone else { return "Connect over USB or Wi-Fi" }
        return phone.connection.isConnected ? phone.transportSummary : phone.statusText
    }
}
