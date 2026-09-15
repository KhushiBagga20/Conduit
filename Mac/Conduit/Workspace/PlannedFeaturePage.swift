//
//  PlannedFeaturePage.swift
//  Conduit
//
//  Sections for features that are not built yet. They are in the sidebar so
//  the shape of the product is visible, and they say plainly that they are
//  planned and what they will need — no controls that do nothing.
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

        ContentUnavailableView {
            Label(section.title, systemImage: section.symbol)
        } description: {
            Text(feature.detail)
        } actions: {
            AvailabilityLabel(availability: availability)
                .font(.callout)
        }
        .navigationTitle(section.title)
    }
}
