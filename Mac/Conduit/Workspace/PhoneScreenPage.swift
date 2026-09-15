//
//  PhoneScreenPage.swift
//  Conduit
//
//  The live phone screen. Rendering and input are the proven scrcpy client
//  in ConduitMedia (PhoneScreenView); this page adds standard toolbar
//  controls and says clearly what is happening when the picture is not there.
//

import ConduitDesign
import ConduitMedia
import ConduitProtocol
import ConduitState
import SwiftUI

struct PhoneScreenPage: View {
    @Environment(ConduitStore.self) private var store

    var body: some View {
        let status = store.mirroring.status

        ZStack {
            if status.isActive {
                Color.black.ignoresSafeArea()
            }

            if let session = store.mirroring.session, let renderer = session.stream.renderer,
               session.stream.state == .connected {
                PhoneScreenView(renderer: renderer, input: session.input)
                    .padding(8)
            }

            if status != .running {
                overlay(for: status)
            }
        }
        .navigationTitle("Phone Screen")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    // MARK: - States

    @ViewBuilder
    private func overlay(for status: MirroringStatus) -> some View {
        switch status {
        case .idle:
            if let phone = store.activePhone, phone.connection.isConnected {
                ContentUnavailableView {
                    Label("Mirror \(phone.name)", systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("See the phone's screen here, and control it with this Mac's mouse, trackpad and keyboard.")
                } actions: {
                    Button("Mirror Screen") { store.commands?.startMirroring(phoneID: phone.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                NoPhoneView(tools: store.tools)
            }

        case .starting, .connecting, .reconnecting, .waitingForPhone:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(status.text)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                if status == .waitingForPhone {
                    Text("Mirroring resumes by itself when the phone is back over USB or Wi-Fi.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .environment(\.colorScheme, .dark)

        case .failed(let message):
            ContentUnavailableView {
                Label("Mirroring Stopped", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { store.commands?.restartMirroring() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

        case .running:
            EmptyView()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let session = store.mirroring.session
        let controlReady = session?.control.state == .connected
        let active = store.mirroring.status.isActive

        ToolbarItem {
            ControlGroup {
                Button { session?.input.pressBack() } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .help("Back — or right-click the screen")
                Button { session?.input.pressHome() } label: {
                    Label("Home", systemImage: "circle")
                }
                .help("Home — or middle-click the screen")
                Button { session?.input.pressRecents() } label: {
                    Label("Recent Apps", systemImage: "square")
                }
                .help("Recent apps")
            }
            .disabled(!controlReady)
        }

        ToolbarItem {
            Button { session?.input.rotateDevice() } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            .help("Rotate the phone's screen")
            .disabled(!controlReady)
        }

        ToolbarItem {
            Button { store.commands?.sendMacClipboardToPhone() } label: {
                Label("Send Clipboard", systemImage: "doc.on.clipboard")
            }
            .help("Put this Mac's clipboard on the phone. ⌘V over the screen also pastes.")
            .disabled(!controlReady)
        }

        ToolbarItem {
            Toggle(isOn: Binding(
                get: { store.mirroring.isPhoneScreenOff },
                set: { store.commands?.setPhoneScreen(on: !$0) })) {
                Label("Phone Screen Off", systemImage: "rectangle.portrait.slash")
            }
            .help(store.mirroring.isPhoneScreenOff
                  ? "Turn the phone's own screen back on"
                  : "Turn the phone's own screen off while mirroring continues")
            .disabled(!controlReady)
        }

        ToolbarItem {
            if active {
                Button { store.commands?.stopMirroring() } label: {
                    Label("Stop Mirroring", systemImage: "stop.fill")
                }
                .help("Stop mirroring")
            } else if let phone = store.activePhone, phone.connection.isConnected {
                Button { store.commands?.startMirroring(phoneID: phone.id) } label: {
                    Label("Mirror Screen", systemImage: "play.fill")
                }
                .help("Start mirroring")
            }
        }
    }

    private var subtitle: String {
        guard let session = store.mirroring.session, session.stream.videoWidth > 0 else {
            return store.activePhone?.name ?? ""
        }
        let transport = store.mirroring.transport == .wifi ? "Wi-Fi" : "USB"
        return "\(session.stream.videoWidth) × \(session.stream.videoHeight) · \(transport)"
    }
}
