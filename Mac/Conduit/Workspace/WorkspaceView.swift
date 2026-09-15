//
//  WorkspaceView.swift
//  Conduit
//
//  The full Mac workspace: a native sidebar and one page per section.
//  Pages read ConduitStore and call ConduitCommands; none of them owns a
//  connection, so closing this window leaves the phone connected.
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
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            page(for: router.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { AppPresentation.workspaceDidOpen() }
        .onDisappear { AppPresentation.workspaceDidClose() }
    }

    @ViewBuilder
    private func page(for section: WorkspaceRouter.Section) -> some View {
        switch section {
        case .overview: OverviewPage()
        case .phoneScreen: PhoneScreenPage()
        case .clipboard: ClipboardPage()
        case .activity: ActivityPage()
        case .devices: DevicesPage()
        case .settings: SettingsPage()
        case .trackpad, .camera, .calls, .links:
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
            Section {
                row(.overview)
                row(.phoneScreen)
                row(.trackpad)
                row(.camera)
            } header: {
                Text("Phone")
            }

            Section {
                row(.calls)
                row(.links)
                row(.clipboard)
            } header: {
                Text("Continuity")
            }

            Section {
                row(.activity)
                row(.devices)
                row(.settings)
            } header: {
                Text("Conduit")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            phoneHeader
                .padding(.horizontal, DesignTokens.Spacing.m)
                .padding(.bottom, DesignTokens.Spacing.s)
        }
    }

    private func row(_ section: WorkspaceRouter.Section) -> some View {
        let availability = section.feature.flatMap { store.activePhone?.availability($0) }
        let mirroringActive = section == .phoneScreen && store.mirroring.status.isActive

        return Label {
            HStack {
                Text(section.title)
                Spacer()
                if mirroringActive {
                    StatusDot(store.mirroring.status.tone, size: 6)
                } else if let availability, availability == .planned || availability == .unsupported {
                    Text(DesignTokens.availabilityLabel[availability.rawValue] ?? "")
                        .font(DesignTokens.Typography.caption.font)
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            Image(systemName: section.symbol)
        }
        .tag(section)
    }

    @ViewBuilder
    private var phoneHeader: some View {
        HStack(spacing: DesignTokens.Spacing.s) {
            ConduitMark(size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.activePhone?.name ?? DesignTokens.Brand.name)
                    .font(DesignTokens.Typography.headline.font)
                    .lineLimit(1)
                HStack(spacing: DesignTokens.Spacing.xs) {
                    StatusDot(store.activePhone?.statusTone ?? .idle, size: 6)
                    Text(store.activePhone?.statusText ?? DesignTokens.Term.notConnected)
                        .font(DesignTokens.Typography.caption.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, DesignTokens.Spacing.xs)
    }
}

// MARK: - Shared page chrome

/// A scrolling page with Conduit's standard margins.
struct PageScroll<Content: View>: View {
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot
    @ViewBuilder let content: Content

    var body: some View {
        if isRenderingSnapshot {
            // Scroll views do not draw into offscreen captures.
            page
        } else {
            ScrollView { page }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            content
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// Set only by the debug snapshot renderer.
    @Entry var isRenderingSnapshot = false
}

struct SectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(title)
                .font(DesignTokens.Typography.title.font)
            if let detail {
                Text(detail)
                    .font(DesignTokens.Typography.callout.font)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
