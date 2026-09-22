//
//  OverviewPage.swift
//  Conduit
//
//  The phone at a glance, laid out the way System Settings lays out a
//  device: a header row, then grouped sections of facts.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct OverviewPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let phone = store.activePhone {
                form(phone)
            } else {
                NoPhoneView(tools: store.tools)
            }
        }
        .navigationTitle("Overview")
    }

    private func form(_ phone: PhoneDevice) -> some View {
        Form {
            Section {
                header(phone)
            }

            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 5) {
                        StatusDot(phone.statusTone, size: 7)
                        Text(phone.statusText)
                    }
                }
                LabeledContent("Connected over", value: phone.transportSummary)
                LabeledContent("Mirroring", value: store.mirroring.status.text)
                LabeledContent("Model", value: phone.modelText)
                LabeledContent("Software", value: phone.androidVersionText)
            }

            let current = FeatureID.allCases.filter { store.availability($0) != .planned }
            Section("Features") {
                ForEach(current, id: \.self) { feature in
                    LabeledContent {
                        AvailabilityLabel(availability: store.availability(feature))
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(feature.title)
                                Text(feature.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: feature.symbol)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }

            let planned = FeatureID.allCases.filter { store.availability($0) == .planned }
            if !planned.isEmpty {
                Section {
                    LabeledContent("Planned", value: planned.map(\.title).formatted(.list(type: .and)))
                } header: {
                    Text("Coming to Conduit")
                } footer: {
                    Text("These arrive with Conduit for Android. Nothing here is a switch that does nothing.")
                }
            }

            Section {
                if store.activity.isEmpty {
                    Text("Connections, mirroring and clipboard syncs will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.activity.prefix(4)) { event in
                        LabeledContent {
                            Text(event.date, format: .dateTime.hour().minute())
                                .foregroundStyle(.secondary)
                        } label: {
                            Label {
                                Text(event.title)
                            } icon: {
                                Image(systemName: event.symbol)
                                    .foregroundStyle(event.tone.color)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent Activity")
                    Spacer()
                    if !store.activity.isEmpty {
                        Button("Show All") { router.section = .activity }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func header(_ phone: PhoneDevice) -> some View {
        HStack(spacing: 14) {
            DeviceIcon(tone: phone.statusTone, size: 52)
            PhoneTitle(phone: phone, large: true)
            Spacer()
            if phone.connection.isConnected {
                if store.mirroring.status.isActive {
                    Button("Show Screen") { openWindow(id: WorkspaceRouter.phoneWindowID) }
                        .controlSize(.large)
                } else {
                    Button {
                        store.commands?.startMirroring(phoneID: phone.id)
                        openWindow(id: WorkspaceRouter.phoneWindowID)
                    } label: {
                        Label("Mirror Screen", systemImage: "rectangle.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
