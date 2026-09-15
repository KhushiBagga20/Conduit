//
//  PhoneScreenPage.swift
//  Conduit
//
//  The live phone screen. Rendering and input are the proven scrcpy client
//  in ConduitMedia (PhoneScreenView); this page adds the controls around it
//  and says clearly what is happening when the picture is not there.
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
            Color.black.opacity(status.isActive ? 1 : 0)
                .ignoresSafeArea()

            if let session = store.mirroring.session, let renderer = session.stream.renderer,
               session.stream.state == .connected {
                PhoneScreenView(renderer: renderer, input: session.input)
                    .padding(DesignTokens.Spacing.m)
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
            idleState
        case .starting, .connecting, .reconnecting:
            VStack(spacing: DesignTokens.Spacing.m) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(status.text)
                    .font(DesignTokens.Typography.body.font)
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .failed(let message):
            VStack(spacing: DesignTokens.Spacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(DesignTokens.Color.statusError.color)
                Text("Mirroring stopped")
                    .font(DesignTokens.Typography.title.font)
                Text(message)
                    .font(DesignTokens.Typography.body.font)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") { store.commands?.restartMirroring() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(DesignTokens.Spacing.xl)
        case .running:
            EmptyView()
        }
    }

    @ViewBuilder
    private var idleState: some View {
        VStack(spacing: DesignTokens.Spacing.l) {
            PhoneGlyph(tone: store.activePhone?.statusTone ?? .idle, size: 72)

            if let phone = store.activePhone, phone.connection.isConnected {
                Text("Mirror \(phone.name)")
                    .font(DesignTokens.Typography.display.font)
                Text("See the phone's screen here and control it with your mouse, trackpad and keyboard.")
                    .font(DesignTokens.Typography.body.font)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Button {
                    store.commands?.startMirroring(phoneID: phone.id)
                } label: {
                    Label(DesignTokens.Term.mirrorScreen, systemImage: "play.fill")
                        .padding(.horizontal, DesignTokens.Spacing.s)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            } else {
                NoPhoneMessage(tools: store.tools)
                    .frame(maxWidth: 420)
            }
        }
        .padding(DesignTokens.Spacing.xxl)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let session = store.mirroring.session
        let controlReady = session?.control.state == .connected

        ToolbarItemGroup(placement: .navigation) {
            if store.mirroring.status.isActive {
                StatusDot(store.mirroring.status.tone, size: 8)
                    .help(store.mirroring.status.text)
            }
        }

        ToolbarItemGroup {
            Button { session?.input.pressBack() } label: { Label("Back", systemImage: "chevron.backward") }
                .help("Back (or right-click the screen)")
                .disabled(!controlReady)
            Button { session?.input.pressHome() } label: { Label("Home", systemImage: "circle") }
                .help("Home (or middle-click the screen)")
                .disabled(!controlReady)
            Button { session?.input.pressRecents() } label: { Label("Recent Apps", systemImage: "square") }
                .help("Recent apps")
                .disabled(!controlReady)
        }

        ToolbarItemGroup {
            Button { store.commands?.sendMacClipboardToPhone() } label: {
                Label("Send Clipboard", systemImage: "doc.on.clipboard")
            }
            .help("Put the Mac clipboard on the phone (⌘V over the screen also pastes)")
            .disabled(!controlReady)

            Button { session?.input.rotateDevice() } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            .help("Rotate the phone's screen")
            .disabled(!controlReady)

            Button { session?.input.toggleDisplayPower() } label: {
                Label(session?.input.isDisplayOn == false ? "Turn Screen On" : "Turn Screen Off",
                      systemImage: session?.input.isDisplayOn == false ? "display" : "power")
            }
            .help("Turn the phone's own screen off while mirroring keeps working")
            .disabled(!controlReady)
        }

        ToolbarItem {
            if store.mirroring.status.isActive {
                Button { store.commands?.stopMirroring() } label: {
                    Label("Stop Mirroring", systemImage: "stop.fill")
                }
                .help("Stop mirroring")
            }
        }
    }

    private var subtitle: String {
        guard let session = store.mirroring.session, session.stream.videoWidth > 0 else {
            return store.activePhone?.name ?? ""
        }
        let transport = store.mirroring.transport == .wifi ? "Wi-Fi" : "USB"
        return "\(session.stream.videoWidth)×\(session.stream.videoHeight) · \(session.stream.codecName ?? "") · \(transport)"
    }
}
