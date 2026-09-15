//
//  OverviewPage.swift
//  Conduit
//
//  The phone at a glance: who it is, how it is connected, what it can do
//  right now, and what just happened.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct OverviewPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router

    var body: some View {
        PageScroll {
            if let phone = store.activePhone {
                hero(phone)
                quickActions(phone)
                features(phone)
            } else {
                NoPhoneMessage(tools: store.tools)
                    .conduitCard(padding: DesignTokens.Spacing.xl)
            }
            activity
        }
        .navigationTitle("Overview")
    }

    // MARK: - Hero

    private func hero(_ phone: PhoneDevice) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            PhoneSummary(phone: phone, size: .large)

            Divider()

            HStack(spacing: DesignTokens.Spacing.xxl) {
                fact("Connection", phone.connection.isConnected ? phone.transportSummary : "—")
                fact("Mirroring", store.mirroring.status.isActive ? store.mirroring.status.text : "Off")
                fact("Battery", phone.battery.map { "\($0.level)%\($0.charging ? " · Charging" : "")" } ?? "Needs Conduit for Android")
                fact("Last seen", phone.connection.isConnected ? "Now"
                     : phone.lastSeen?.formatted(.relative(presentation: .named)) ?? "—")
            }
        }
        .conduitCard(padding: DesignTokens.Spacing.xl)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(label)
                .font(DesignTokens.Typography.caption.font)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(DesignTokens.Typography.callout.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Quick actions

    private func quickActions(_ phone: PhoneDevice) -> some View {
        let mirroring = store.mirroring.status.isActive

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            SectionHeading(title: "Quick Actions")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.m), count: 3),
                      spacing: DesignTokens.Spacing.m) {
                QuickActionTile(title: mirroring ? "Show Screen" : DesignTokens.Term.mirrorScreen,
                                symbol: "rectangle.on.rectangle",
                                availability: phone.availability(.mirroring)) {
                    router.section = .phoneScreen
                    if !mirroring { store.commands?.startMirroring(phoneID: phone.id) }
                }
                QuickActionTile(title: DesignTokens.Term.useAsTrackpad, symbol: "hand.point.up.left",
                                availability: phone.availability(.trackpad)) {}
                QuickActionTile(title: DesignTokens.Term.useCamera, symbol: "camera",
                                availability: phone.availability(.camera)) {}
                QuickActionTile(title: DesignTokens.Term.shareLink, symbol: "link",
                                availability: phone.availability(.links)) {}
                QuickActionTile(title: DesignTokens.Term.callPhone, symbol: "phone",
                                availability: phone.availability(.calls)) {}
                QuickActionTile(title: DesignTokens.Term.findMac, symbol: "laptopcomputer",
                                availability: phone.availability(.findMac)) {}
            }
        }
    }

    // MARK: - Features

    private func features(_ phone: PhoneDevice) -> some View {
        let current = FeatureID.allCases.filter { phone.availability($0) != .planned }
        let planned = FeatureID.allCases.filter { phone.availability($0) == .planned }

        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            SectionHeading(title: "Features", detail: "What works with \(phone.name) right now.")

            VStack(spacing: 0) {
                ForEach(Array(current.enumerated()), id: \.element) { index, feature in
                    if index > 0 { Divider().padding(.leading, 44) }
                    HStack(spacing: DesignTokens.Spacing.m) {
                        Image(systemName: feature.symbol)
                            .frame(width: 20)
                            .foregroundStyle(DesignTokens.Color.accent.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feature.title)
                                .font(DesignTokens.Typography.body.font)
                            if !phone.availability(feature).isUsable {
                                Text(feature.plannedDetail)
                                    .font(DesignTokens.Typography.caption.font)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        AvailabilityBadge(phone.availability(feature))
                    }
                    .padding(.vertical, DesignTokens.Spacing.s)
                }

                if !planned.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                        HStack {
                            Text("Coming to Conduit")
                                .font(DesignTokens.Typography.headline.font)
                            AvailabilityBadge(.planned)
                        }
                        Text(planned.map(\.title).joined(separator: " · "))
                            .font(DesignTokens.Typography.callout.font)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DesignTokens.Spacing.m)
                    .padding(.bottom, DesignTokens.Spacing.xs)
                }
            }
            .conduitCard(padding: DesignTokens.Spacing.m)
        }
    }

    // MARK: - Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack {
                SectionHeading(title: "Recent Activity")
                Spacer()
                if !store.activity.isEmpty {
                    Button("Show All") { router.section = .activity }
                        .buttonStyle(.link)
                }
            }

            if store.activity.isEmpty {
                Text("Nothing yet. Connections, mirroring and clipboard syncs will appear here.")
                    .font(DesignTokens.Typography.callout.font)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: DesignTokens.Spacing.s) {
                    ForEach(store.activity.prefix(5)) { ActivityRow(event: $0) }
                }
                .conduitCard(padding: DesignTokens.Spacing.m)
            }
        }
    }
}
