//
//  TrackpadPage.swift
//  Conduit
//
//  The phone as this Mac's trackpad: what it needs, how it behaves, and
//  whether it is in use right now.
//
//  Moving the pointer is what macOS Accessibility permission governs, so the
//  page says plainly when Conduit does not have it — the phone can be
//  swiping away with nothing to show for it otherwise.
//

import AppKit
import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct TrackpadPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router

    var body: some View {
        Group {
            if store.link.phones.isEmpty {
                ContentUnavailableView {
                    Label("Trackpad", systemImage: "hand.point.up.left")
                } description: {
                    Text("The trackpad travels over Conduit Link. Link a phone first: in Conduit for Android, choose Add Mac.")
                } actions: {
                    Button("Open Devices") { router.section = .devices }
                }
            } else {
                form
            }
        }
        .navigationTitle("Trackpad")
        // macOS grants Accessibility outside the app, so the page keeps
        // looking while it is open rather than waiting for a restart.
        .task {
            while !Task.isCancelled {
                store.commands?.refreshTrackpadPermission()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var form: some View {
        @Bindable var store = store

        return Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 5) {
                        StatusDot(statusTone, size: 7)
                        Text(statusText)
                    }
                }
                Text("On the phone, open Conduit → Features → Trackpad. One finger moves the pointer, a tap clicks, two fingers scroll, and two fingers tapped together are a right click.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("The Phone as a Trackpad")
            }

            if !store.link.trackpadTrusted {
                Section {
                    LabeledContent {
                        Button("Allow Conduit") { store.commands?.requestTrackpadPermission() }
                    } label: {
                        Text("Let Conduit move the pointer")
                        Text("macOS only lets an app move the pointer after you allow it under Privacy & Security → Accessibility. Conduit uses it for nothing else.")
                    }
                    Button("Open Accessibility Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } header: {
                    Text("Permission")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { store.preferences.phoneTrackpad },
                    set: { value in store.commands?.updatePreferences { $0.phoneTrackpad = value } })) {
                    Text("Let the phone control this Mac")
                    Text("Only a phone you have paired, and only while its trackpad screen is open.")
                }

                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { store.preferences.trackpadSensitivity },
                            set: { value in store.commands?.updatePreferences { $0.trackpadSensitivity = value } }),
                               in: 0.5 ... 3, step: 0.1)
                            .frame(width: 180)
                        Text(String(format: "%.1f×", store.preferences.trackpadSensitivity))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Pointer speed")
                }

                Toggle(isOn: Binding(
                    get: { store.preferences.naturalScrolling },
                    set: { value in store.commands?.updatePreferences { $0.naturalScrolling = value } })) {
                    Text("Content follows the fingers")
                    Text("Scrolling the way macOS scrolls by default. Turn it off to scroll the other way.")
                }

                Toggle(isOn: Binding(
                    get: { store.preferences.trackpadHaptics },
                    set: { value in store.commands?.updatePreferences { $0.trackpadHaptics = value } })) {
                    Text("Buzz the phone on click")
                    Text("A short vibration on the phone as each click lands here.")
                }
            } header: {
                Text("Behaviour")
            }
        }
        .formStyle(.grouped)
    }

    private var statusTone: StatusTone {
        if !store.link.trackpadTrusted { return .error }
        if !store.preferences.phoneTrackpad { return .idle }
        return store.link.trackpadActive ? .connected : .idle
    }

    private var statusText: String {
        if !store.link.trackpadTrusted { return "Conduit is not allowed to move the pointer" }
        if !store.preferences.phoneTrackpad { return "Off" }
        if store.link.trackpadActive { return "The phone is moving the pointer" }
        return store.link.hasConnectedPhone ? "Ready" : "No linked phone is connected"
    }
}
