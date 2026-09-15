//
//  PlannedFeaturePage.swift
//  Conduit
//
//  Sections for features that are not built yet. They exist in the sidebar
//  so the shape of the product is visible — and say plainly that they are
//  planned and what they will need, instead of offering controls that do
//  nothing.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct PlannedFeaturePage: View {
    @Environment(ConduitStore.self) private var store
    let section: WorkspaceRouter.Section

    var body: some View {
        let feature = section.feature ?? .trackpad
        let availability = store.activePhone?.availability(feature) ?? .planned

        VStack(spacing: DesignTokens.Spacing.l) {
            Image(systemName: section.symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DesignTokens.Color.accent.color)
                .frame(width: 88, height: 88)
                .background(DesignTokens.Color.accent.color.opacity(0.1), in: Circle())

            HStack(spacing: DesignTokens.Spacing.s) {
                Text(section.title)
                    .font(DesignTokens.Typography.display.font)
                AvailabilityBadge(availability)
            }

            Text(feature.plannedDetail)
                .font(DesignTokens.Typography.body.font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(section.title)
    }
}
