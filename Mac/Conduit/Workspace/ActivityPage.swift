//
//  ActivityPage.swift
//  Conduit
//
//  Everything that happened this session, newest first, in a standard
//  table. Entries say what happened, never what was in it.
//

import ConduitDesign
import ConduitState
import SwiftUI

struct ActivityPage: View {
    @Environment(ConduitStore.self) private var store
    @State private var selection: ActivityEvent.ID?

    var body: some View {
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Phones connecting, mirroring, reconnections and clipboard syncs appear here."))
            } else {
                Table(store.activity, selection: $selection) {
                    TableColumn("Event") { event in
                        Label {
                            Text(event.title)
                        } icon: {
                            Image(systemName: event.symbol)
                                .foregroundStyle(event.tone.color)
                        }
                    }
                    .width(min: 180, ideal: 240)

                    TableColumn("Details") { event in
                        Text(event.detail ?? "")
                            .foregroundStyle(.secondary)
                            .help(event.detail ?? "")
                    }

                    TableColumn("Time") { event in
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Button { store.commands?.clearActivity() } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Clear activity")
                .disabled(store.activity.isEmpty)
            }
        }
    }
}
