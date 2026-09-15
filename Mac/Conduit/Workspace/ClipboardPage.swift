//
//  ClipboardPage.swift
//  Conduit
//
//  Clipboard sync as it works today: through the mirroring session, in both
//  directions. Conduit keeps no clipboard history — clipboards hold
//  passwords and codes, and the safest history is none.
//

import ConduitDesign
import ConduitMedia
import ConduitState
import SwiftUI

struct ClipboardPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let controlReady = store.mirroring.session?.control.state == .connected

        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { store.preferences.clipboardSync },
                    set: { value in store.commands?.updatePreferences { $0.clipboardSync = value } })) {
                    Text("Sync the phone's clipboard to this Mac")
                    Text("Text you copy on the phone lands on this Mac's clipboard.")
                }
            } footer: {
                Text("Clipboard sync works while the phone's screen is being mirrored.")
            }

            Section("Status") {
                LabeledContent("Phone to Mac") {
                    HStack(spacing: 5) {
                        StatusDot(controlReady && store.preferences.clipboardSync ? .connected : .idle, size: 7)
                        Text(phoneToMacText(controlReady: controlReady))
                    }
                }
                LabeledContent("Mac to phone") {
                    HStack(spacing: 5) {
                        StatusDot(controlReady ? .connected : .idle, size: 7)
                        Text(controlReady ? "Press ⌘V over the phone screen" : "Available while mirroring")
                    }
                }
            }

            Section {
                HStack {
                    Button("Send Mac Clipboard to Phone") { store.commands?.sendMacClipboardToPhone() }
                        .disabled(!controlReady)
                    Spacer()
                    if !store.mirroring.status.isActive {
                        Button("Start Mirroring") {
                            store.commands?.startMirroring(phoneID: nil)
                            openWindow(id: WorkspaceRouter.phoneWindowID)
                        }
                        .disabled(store.activePhone?.connection.isConnected != true)
                    }
                }
            } footer: {
                Label("Clipboards often hold passwords and one-time codes. Conduit keeps no clipboard history and never writes clipboard text to its logs.",
                      systemImage: "lock.shield")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
    }

    private func phoneToMacText(controlReady: Bool) -> String {
        if !store.preferences.clipboardSync { return "Off" }
        if !store.mirroring.status.isActive { return "Starts when mirroring starts" }
        return controlReady ? "Syncing" : "Connecting…"
    }
}
