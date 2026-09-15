//
//  ActivityPage.swift
//  Conduit
//
//  Everything that happened this session, newest first. Entries say what
//  happened, never what was in it.
//

import ConduitDesign
import ConduitState
import SwiftUI

struct ActivityPage: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Phones connecting, mirroring, reconnections and clipboard syncs will appear here."))
            } else {
                List(store.activity) { event in
                    ActivityRow(event: event, showsDetail: true)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            Button("Clear") { store.commands?.clearActivity() }
                .disabled(store.activity.isEmpty)
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    var showsDetail = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.m) {
            Image(systemName: event.symbol)
                .foregroundStyle(event.tone.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(DesignTokens.Typography.body.font)
                if showsDetail || event.isError, let detail = event.detail {
                    Text(detail)
                        .font(DesignTokens.Typography.callout.font)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(event.date, format: .dateTime.hour().minute())
                .font(DesignTokens.Typography.caption.font)
                .foregroundStyle(.tertiary)
        }
    }
}
