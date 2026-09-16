//
//  PhoneScreenPage.swift
//  Conduit
//
//  The workspace's view of mirroring. The phone screen itself lives in its
//  own window (PhoneWindowView) so the workspace never has to be on screen
//  while you use the phone; this page starts mirroring, brings that window
//  back, and shows how the session is running.
//

import ConduitDesign
import ConduitMedia
import ConduitProtocol
import ConduitState
import SwiftUI

struct PhoneScreenPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = store.mirroring.status

        Group {
            if status.isActive {
                activeForm(status)
            } else if case .failed(let message) = status {
                ContentUnavailableView {
                    Label("Mirroring Stopped", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        store.commands?.restartMirroring()
                        openWindow(id: WorkspaceRouter.phoneWindowID)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else if let phone = store.activePhone, phone.connection.isConnected {
                ContentUnavailableView {
                    Label("Mirror \(phone.name)", systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("The phone's screen opens in a window of its own. Control it with this Mac's mouse, trackpad and keyboard.")
                } actions: {
                    Button("Mirror Screen") { start(phone) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                NoPhoneView(tools: store.tools)
            }
        }
        .navigationTitle("Phone Screen")
        .toolbar {
            ToolbarItem {
                if status.isActive {
                    Button { store.commands?.stopMirroring() } label: {
                        Label("Stop Mirroring", systemImage: "stop.fill")
                    }
                    .help("Stop mirroring")
                }
            }
        }
    }

    private func activeForm(_ status: MirroringStatus) -> some View {
        let stream = store.mirroring.session?.stream

        return Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mirroring in its own window")
                            .font(.headline)
                        HStack(spacing: 5) {
                            StatusDot(status.tone, size: 7)
                            Text(status.text).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Show Phone Window") { openWindow(id: WorkspaceRouter.phoneWindowID) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }

            Section("Session") {
                LabeledContent("Connected over", value: store.mirroring.transport == .wifi ? "Wi-Fi" : "USB")
                LabeledContent("Resolution") {
                    if let stream, stream.videoWidth > 0 {
                        Text("\(stream.videoWidth) × \(stream.videoHeight)")
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("Phone screen", value: store.mirroring.isPhoneScreenOff ? "Off" : "On")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { store.mirroring.isPhoneScreenOff },
                    set: { store.commands?.setPhoneScreen(on: !$0) })) {
                    Text("Turn the phone's screen off")
                    Text(screenOffDetail)
                }
                .disabled(store.mirroring.session?.control.state != .connected)
            }
        }
        .formStyle(.grouped)
    }

    private var screenOffDetail: String {
        guard store.mirroring.isPhoneScreenOff else {
            return "Mirroring continues. With Conduit for Android on the phone, touches on its own screen are ignored until it is back on."
        }
        switch store.mirroring.touchGuard {
        case .off, .starting:
            return "Making the phone ignore touches on its screen…"
        case .active:
            return "Touches on the phone are ignored. This Mac keeps control."
        case .unavailable(let reason):
            return reason
        }
    }

    private func start(_ phone: PhoneDevice) {
        store.commands?.startMirroring(phoneID: phone.id)
        openWindow(id: WorkspaceRouter.phoneWindowID)
    }
}
