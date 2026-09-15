//
//  DevicesPage.swift
//  Conduit
//
//  Every phone this Mac knows: connected now, or remembered from before.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct DevicesPage: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        PageScroll {
            SectionHeading(title: "Phones",
                           detail: "Phones connect over USB debugging or Wireless debugging. Conduit remembers them and reconnects over Wi-Fi when it can.")

            if store.phones.isEmpty {
                NoPhoneMessage(tools: store.tools)
                    .conduitCard(padding: DesignTokens.Spacing.xl)
            } else {
                VStack(spacing: DesignTokens.Spacing.m) {
                    ForEach(store.phones) { phone in
                        row(phone)
                    }
                }
            }

            pairingNote
        }
        .navigationTitle("Devices")
        .toolbar {
            Button { store.commands?.refreshPhones() } label: {
                Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Look for attached phones again")
        }
    }

    private func row(_ phone: PhoneDevice) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.l) {
            PhoneSummary(phone: phone)

            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xs) {
                if phone.connection.isConnected {
                    Text(phone.transportSummary)
                        .font(DesignTokens.Typography.callout.font)
                        .foregroundStyle(.secondary)
                }
                if !phone.detailLine.isEmpty {
                    Text(phone.detailLine)
                        .font(DesignTokens.Typography.caption.font)
                        .foregroundStyle(.tertiary)
                }
            }

            Menu {
                if phone.connection.isConnected, store.activePhoneID != phone.id {
                    Button("Use This Phone") { store.commands?.selectPhone(phone.id) }
                }
                if phone.isPreferred {
                    Button("Stop Preferring") { store.commands?.setPreferredPhone(nil) }
                } else {
                    Button("Prefer This Phone") { store.commands?.setPreferredPhone(phone.id) }
                }
            } label: {
                Image(systemName: phone.isPreferred ? "star.fill" : "ellipsis.circle")
                    .foregroundStyle(phone.isPreferred ? DesignTokens.Color.accent.color : .secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(phone.isPreferred ? "Preferred phone" : "More")
        }
        .conduitCard(padding: DesignTokens.Spacing.m)
        .overlay(alignment: .topLeading) {
            if store.activePhoneID == phone.id, store.phones.count > 1 {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.large, style: .continuous)
                    .strokeBorder(DesignTokens.Color.accent.color.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    private var pairingNote: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.m) {
            Image(systemName: "lock.shield")
                .foregroundStyle(DesignTokens.Color.accent.color)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack {
                    Text("Pairing with Conduit for Android")
                        .font(DesignTokens.Typography.headline.font)
                    AvailabilityBadge(.planned)
                }
                Text("Code pairing between this Mac and the Android app — for calls, link sharing and the trackpad — arrives with Conduit for Android.")
                    .font(DesignTokens.Typography.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .conduitCard(padding: DesignTokens.Spacing.m)
    }
}
