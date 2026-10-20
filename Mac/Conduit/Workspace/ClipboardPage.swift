//
//  ClipboardPage.swift
//  Conduit
//
//  Clipboard sync between this Mac and the phone, both ways, without
//  mirroring. Each direction has its own limit, and the page names it:
//  macOS asks before an app reads the clipboard by itself, and Android lets
//  no app read it in the background at all.
//
//  Conduit keeps no clipboard history — clipboards hold passwords and
//  codes, and the safest history is none.
//

import AppKit
import ConduitDesign
import ConduitState
import SwiftUI

struct ClipboardPage: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { store.preferences.clipboardSync },
                    set: { value in store.commands?.updatePreferences { $0.clipboardSync = value } })) {
                    Text("Sync the clipboard with the phone")
                    Text("Copy on one, paste on the other. Text only, and never anything a password manager marks private.")
                }
            }

            if store.preferences.clipboardSync {
                Section("This Mac to the Phone") {
                    LabeledContent("Status") {
                        HStack(spacing: 5) {
                            StatusDot(macToPhoneTone, size: 7)
                            Text(macToPhoneText)
                        }
                    }
                    if store.clipboard.macAccess != .allowed {
                        LabeledContent {
                            Button(store.clipboard.macAccess == .denied ? "Open Settings" : "Allow…") { allowReading() }
                        } label: {
                            Text("Let Conduit read what you copy")
                            Text("macOS asks before an app reads the clipboard by itself. In System Settings → Privacy & Security → Paste from Other Apps, set Conduit to Always Allow — until then, use Send Clipboard to Phone below.")
                        }
                    }
                }

                Section("The Phone to This Mac") {
                    LabeledContent("Status") {
                        HStack(spacing: 5) {
                            StatusDot(store.clipboard.phoneToMacAutomatic ? .connected : .idle, size: 7)
                            Text(store.clipboard.phoneToMacAutomatic
                                 ? "Automatic, while the phone is connected over USB or Wi-Fi"
                                 : "One tap on the phone")
                        }
                    }
                    Text(store.clipboard.phoneToMacAutomatic
                         ? "Anything copied on the phone lands here by itself."
                         : "Android lets no app read the clipboard in the background. Connect the phone over USB or Wi-Fi debugging for automatic sync, or on the phone use Share → Send to Mac, or the Conduit tile in Quick Settings.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Send Clipboard to Phone") { store.commands?.sendMacClipboardToPhone() }
                    .disabled(!store.clipboard.canReachPhone)
            } footer: {
                Label("Clipboards often hold passwords and one-time codes. Conduit keeps no clipboard history and never writes clipboard text to its logs.",
                      systemImage: "lock.shield")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
        // macOS's choice is made in System Settings, so the page keeps
        // looking while it is open.
        .task {
            while !Task.isCancelled {
                store.commands?.refreshClipboardStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var macToPhoneTone: StatusTone {
        guard store.clipboard.canReachPhone else { return .idle }
        return store.clipboard.macAccess == .allowed ? .connected : .working
    }

    private var macToPhoneText: String {
        guard store.clipboard.canReachPhone else { return "No phone to reach right now" }
        switch store.clipboard.macAccess {
        case .allowed: return "Automatic"
        case .asks: return "Needs permission from macOS"
        case .denied: return "macOS is set to deny Conduit"
        }
    }

    private func allowReading() {
        if store.clipboard.macAccess == .asks {
            // One read at the person's request makes macOS ask, and list
            // Conduit where Always Allow can be chosen.
            store.commands?.requestMacClipboardAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
