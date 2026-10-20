//
//  SettingsPage.swift
//  Conduit
//
//  Preferences that exist today, shown both in the workspace sidebar and in
//  the standard Settings window (⌘,). Settings for features that are not
//  built yet are not shown — a switch that does nothing is worse than none.
//

import AppKit
import ConduitDesign
import ConduitState
import SwiftUI

/// The native Settings window.
struct SettingsWindow: View {
    var body: some View {
        SettingsForm()
            .frame(width: 520, height: 560)
    }
}

struct SettingsForm: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        Form {
            Section {
                Picker(selection: binding(\.mirroring.lowLatency)) {
                    Text("Best quality").tag(false)
                    Text("Lowest latency").tag(true)
                } label: {
                    Text("Picture")
                    Text("Lowest latency uses 1024 pixels at 4 Mbps.")
                }
                .pickerStyle(.segmented)

                Toggle(isOn: binding(\.mirroring.adaptToWiFi)) {
                    Text("Adapt quality over Wi-Fi")
                    Text("Caps the picture at 1280 pixels on a wireless connection.")
                }
                Toggle(isOn: binding(\.mirroring.audio)) {
                    Text("Play phone audio on this Mac")
                    Text("Needs Android 11 or later.")
                }
                Toggle(isOn: binding(\.mirroring.stayAwake)) {
                    Text("Keep the phone awake while mirroring")
                    Text("Stops the phone sleeping and dropping a wireless connection.")
                }
            } header: {
                Text("Mirroring")
            } footer: {
                Text("Changes apply the next time mirroring starts.")
            }

            Section("Clipboard") {
                Toggle(isOn: binding(\.clipboardSync)) {
                    Text("Sync the clipboard with the phone")
                    Text("Both ways, without mirroring. Conduit keeps no history.")
                }
            }

            Section("Files") {
                LabeledContent {
                    HStack {
                        Button("Show") { NSWorkspace.shared.open(downloadsFolder) }
                        Button("Change…") { chooseDownloadsFolder() }
                    }
                } label: {
                    Text("Downloads from the phone go to")
                    Text(downloadsFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                }
            }

            Section("Connection") {
                Toggle(isOn: binding(\.autoConnectWireless)) {
                    Text("Reconnect over Wireless debugging")
                    Text("Keeps phones this Mac knows connected over Wi-Fi, so mirroring survives unplugging.")
                }
            }

            Section("About") {
                LabeledContent("Version",
                               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent("Android Debug Bridge") {
                    switch store.tools.adb {
                    case .checking: Text("Checking…")
                    case .available(let path): Text(path).textSelection(.enabled)
                    case .missing: Text("Not installed")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var downloadsFolder: URL { store.preferences.phoneDownloadsFolder }

    private func chooseDownloadsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = downloadsFolder
        panel.prompt = "Use This Folder"
        panel.message = "Files you download from the phone will be saved here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.commands?.updatePreferences { $0.phoneDownloadsPath = url.path }
    }

    private func binding(_ keyPath: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { value in store.commands?.updatePreferences { $0[keyPath: keyPath] = value } })
    }
}
