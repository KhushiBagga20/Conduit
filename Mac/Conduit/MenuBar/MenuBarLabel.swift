//
//  MenuBarLabel.swift
//  Conduit
//
//  The menu bar icon. It changes shape with state rather than colour —
//  menu bar icons are templates, and a status you have to squint at is not
//  a status.
//

import ConduitState
import SwiftUI

struct MenuBarLabel: View {
    let store: ConduitStore

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        if store.mirroring.status.isActive { return "rectangle.on.rectangle" }
        return store.connectedPhones.isEmpty ? "point.topleft.down.to.point.bottomright.curvepath" : "smartphone"
    }

    private var accessibilityText: String {
        if store.mirroring.status.isActive { return "Conduit — mirroring" }
        if let phone = store.connectedPhones.first { return "Conduit — \(phone.name) connected" }
        return "Conduit — no phone connected"
    }
}
