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
        Group {
            if store.phones.isEmpty {
                NoPhoneView(tools: store.tools)
            } else {
                Form {
                    ForEach(store.phones) { phone in
                        section(phone)
                        hotspotSection(phone)
                        companionSection(phone)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem {
                Button { store.commands?.refreshPhones() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Look for attached phones again")
            }
        }
    }

    /// Reaching the phone over its own hotspot, for when there is no Wi-Fi
    /// network to share.
    @ViewBuilder
    private func hotspotSection(_ phone: PhoneDevice) -> some View {
        Section {
            LabeledContent {
                if phone.hotspotArmed {
                    Button("Turn Off") { store.commands?.stopHotspotConnection(phoneID: phone.id) }
                } else {
                    Button("Get Ready") { store.commands?.prepareHotspotConnection(phoneID: phone.id) }
                        .disabled(!phone.connection.isConnected)
                }
            } label: {
                Text("Connect over this phone's hotspot")
                Text(hotspotStatus(phone))
            }

            if phone.hotspotArmed && !phone.isOverHotspot {
                LabeledContent("Next") {
                    Text("Turn on the phone's hotspot, then join this Mac to it")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Anywhere")
        } footer: {
            Label("Android turns Wireless debugging off whenever Wi-Fi is off, so a hotspot needs adb's own port instead. While this is on, the phone accepts adb connections on port \(String(HotspotAccess.port)) over every network it joins, until you turn it off or restart the phone. A computer it has never allowed still has to be allowed on the phone.",
                  systemImage: "exclamationmark.shield")
        }
    }

    private func hotspotStatus(_ phone: PhoneDevice) -> String {
        if phone.isOverHotspot { return "Connected through the phone's hotspot" }
        if phone.hotspotArmed { return "Ready — the phone is listening on port \(String(HotspotAccess.port))" }
        return "Off. Wireless debugging needs a Wi-Fi network both devices are on."
    }

    @ViewBuilder
    private func companionSection(_ phone: PhoneDevice) -> some View {
        Section {
            switch phone.companionApp {
            case .unknown:
                LabeledContent("Conduit for Android", value: phone.connection.isConnected ? "Checking…" : "—")
            case .notInstalled:
                LabeledContent {
                    Text("Not installed").foregroundStyle(.secondary)
                } label: {
                    Text("Conduit for Android")
                    Text("Install it on the phone to keep Wireless debugging on from the phone itself.")
                }
            case .installed(let canManageSettings):
                LabeledContent {
                    if canManageSettings {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(StatusTone.connected.color)
                    } else {
                        Button("Allow") { store.commands?.allowCompanionSettingsControl(phoneID: phone.id) }
                            .disabled(!phone.connection.isConnected)
                    }
                } label: {
                    Text("Wireless debugging control")
                    Text("Lets Conduit for Android turn Wireless debugging on and keep the phone awake while charging, so wireless mirroring stays reachable.")
                }
            }
            LabeledContent {
                AvailabilityLabel(availability: .planned)
            } label: {
                Text("Pair with this Mac")
                Text("For link sharing, calls and using the phone as a trackpad.")
            }
        } header: {
            Text("Conduit for Android")
        }
    }

    private func section(_ phone: PhoneDevice) -> some View {
        Section {
            HStack(spacing: 12) {
                DeviceIcon(tone: phone.statusTone, size: 40)
                PhoneTitle(phone: phone)
                Spacer()
                if store.activePhoneID == phone.id {
                    Text("In Use")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if phone.connection.isConnected {
                    Button("Use This Phone") { store.commands?.selectPhone(phone.id) }
                }
            }
            .padding(.vertical, 4)

            LabeledContent("Connected over", value: phone.connection.isConnected ? phone.transportSummary : "—")
            LabeledContent("Model", value: phone.modelText)
            LabeledContent("Software", value: phone.androidVersionText)
            if !phone.connection.isConnected, let lastSeen = phone.lastSeen {
                LabeledContent("Last seen", value: lastSeen.formatted(.relative(presentation: .named)))
            }
            Toggle(isOn: Binding(
                get: { phone.isPreferred },
                set: { store.commands?.setPreferredPhone($0 ? phone.id : nil) })) {
                Text("Preferred phone")
                Text("Conduit uses this phone first when more than one is connected.")
            }
        }
    }
}
