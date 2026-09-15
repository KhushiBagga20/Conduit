//
//  SettingsPage.swift
//  Conduit
//
//  Preferences that exist today. Settings for features that are not built
//  yet are not shown — a switch that does nothing is worse than no switch.
//

import ConduitDesign
import ConduitState
import SwiftUI

struct SettingsPage: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        Form {
            Section {
                toggle("Low-latency mirroring", \.mirroring.lowLatency,
                       detail: "1024 px at 4 Mbps. Fewer pixels help far more than a lower bitrate on Wi-Fi.")
                toggle("Forward phone audio", \.mirroring.audio,
                       detail: "Plays the phone's sound on this Mac while mirroring. Needs Android 11.")
                toggle("Keep the phone awake", \.mirroring.stayAwake,
                       detail: "Stops the phone sleeping while it is being mirrored.")
                Text("Changes apply the next time mirroring starts.")
                    .font(DesignTokens.Typography.caption.font)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Mirroring")
            }

            Section {
                toggle("Sync the phone's clipboard to this Mac", \.clipboardSync,
                       detail: "While mirroring, text copied on the phone lands on the Mac clipboard. Nothing is stored.")
            } header: {
                Text("Clipboard")
            }

            Section {
                toggle("Reconnect over Wireless debugging", \.autoConnectWireless,
                       detail: "Connects phones this Mac has seen before when they appear on the same network.")
            } header: {
                Text("Connection")
            }

            Section {
                LabeledContent("adb") {
                    switch store.tools.adb {
                    case .checking: Text("Checking…")
                    case .available(let path): Text(path).textSelection(.enabled)
                    case .missing: Text("Not installed — brew install android-platform-tools")
                    }
                }
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<Preferences, Bool>, detail: String) -> some View {
        Toggle(isOn: Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.commands?.updatePreferences { $0[keyPath: keyPath] = value } })) {
            Text(title)
            Text(detail)
        }
    }
}
