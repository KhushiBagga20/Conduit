//
//  PhoneWindowView.swift
//  Conduit
//
//  The phone screen in a window of its own, shaped like the phone: a dark
//  bezel, the screen, and controls that appear when the pointer is over the
//  window. It is what opens when mirroring starts, so the workspace — with
//  its sidebar and toolbar — never has to be on screen to use the phone.
//
//  The window follows the mirroring session: it closes when mirroring stops,
//  and closing it stops mirroring. The connection to the phone is untouched
//  either way.
//

import AppKit
import ConduitDesign
import ConduitMedia
import ConduitState
import SwiftUI

struct PhoneWindowView: View {
    @Environment(ConduitStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var window: NSWindow?
    @State private var hovering = false
    @State private var keepOnTop = false
    @State private var fittedVideoSize: CGSize = .zero

    /// Space above the screen for the traffic lights and controls.
    static let topBarHeight: CGFloat = 38
    /// Bezel around the screen on the other three sides.
    static let bezel: CGFloat = 8
    static let screenCornerRadius: CGFloat = 26

    var body: some View {
        let status = store.mirroring.status

        VStack(spacing: 0) {
            topBar(status: status)
                .frame(height: Self.topBarHeight)

            ZStack {
                RoundedRectangle(cornerRadius: Self.screenCornerRadius, style: .continuous)
                    .fill(Color(white: 0.07))

                if let session = store.mirroring.session, let renderer = session.stream.renderer,
                   session.stream.state == .connected {
                    PhoneScreenView(renderer: renderer, input: session.input,
                                    cornerRadius: Self.screenCornerRadius)
                }

                if status != .running {
                    statusOverlay(status)
                }
            }
            .padding([.horizontal, .bottom], Self.bezel)
        }
        .background(Color.black)
        .background(WindowAccessor { configure($0) })
        .onHover { hovering = $0 }
        .onChange(of: videoSize) { _, size in fit(to: size) }
        .onChange(of: status) { _, newStatus in
            if newStatus == .idle { dismissWindow(id: WorkspaceRouter.phoneWindowID) }
        }
        .onAppear { AppPresentation.windowOpened() }
        .onDisappear {
            AppPresentation.windowClosed()
            if store.mirroring.status != .idle { store.commands?.stopMirroring() }
        }
        .preferredColorScheme(.dark)
        .navigationTitle(store.activePhone?.name ?? "Phone")
    }

    private var videoSize: CGSize {
        guard let stream = store.mirroring.session?.stream, stream.videoWidth > 0, stream.videoHeight > 0 else {
            return .zero
        }
        return CGSize(width: stream.videoWidth, height: stream.videoHeight)
    }

    // MARK: - Top bar

    private func topBar(status: MirroringStatus) -> some View {
        let session = store.mirroring.session
        let controlReady = session?.control.state == .connected
        let showControls = hovering || status != .running

        return HStack(spacing: 2) {
            // Room for the traffic lights.
            Spacer().frame(width: 72)

            Text(store.activePhone?.name ?? "Phone")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .opacity(showControls ? 0 : 1)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                BarButton("Back", systemImage: "chevron.backward") { session?.input.pressBack() }
                    .disabled(!controlReady)
                BarButton("Home", systemImage: "circle") { session?.input.pressHome() }
                    .disabled(!controlReady)
                BarButton("Recent Apps", systemImage: "square") { session?.input.pressRecents() }
                    .disabled(!controlReady)
                Divider().frame(height: 14).overlay(Color.white.opacity(0.15))
                BarButton("Rotate", systemImage: "rotate.right") { session?.input.rotateDevice() }
                    .disabled(!controlReady)
                BarButton(store.mirroring.isPhoneScreenOff ? "Turn Phone Screen On" : "Turn Phone Screen Off",
                          systemImage: store.mirroring.isPhoneScreenOff ? "rectangle.portrait.slash" : "rectangle.portrait",
                          isOn: store.mirroring.isPhoneScreenOff) {
                    store.commands?.setPhoneScreen(on: store.mirroring.isPhoneScreenOff)
                }
                .disabled(!controlReady)

                BarButton(keepOnTop ? "Stop Keeping on Top" : "Keep on Top", systemImage: "pin", isOn: keepOnTop) {
                    keepOnTop.toggle()
                    window?.level = keepOnTop ? .floating : .normal
                }
            }
            .disabled(!controlReady && status == .running)
            .opacity(showControls ? 1 : 0)
            .allowsHitTesting(showControls)
        }
        .padding(.trailing, 10)
        .animation(.easeOut(duration: 0.18), value: showControls)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    // MARK: - Status

    @ViewBuilder
    private func statusOverlay(_ status: MirroringStatus) -> some View {
        switch status {
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(StatusTone.error.color)
                Text("Mirroring Stopped")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Close") { dismissWindow(id: WorkspaceRouter.phoneWindowID) }
                    Button("Try Again") { store.commands?.restartMirroring() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(24)

        case .idle, .running:
            EmptyView()

        default:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(status.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if status == .waitingForPhone {
                    Text("Mirroring resumes when the phone is back over USB or Wi-Fi.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Window

    private func configure(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        if videoSize != .zero { fit(to: videoSize) }
    }

    /// Size the window around the phone's screen: as tall as fits
    /// comfortably, with the bezel, and locked to that shape while resizing.
    private func fit(to video: CGSize) {
        guard let window, video.width > 0, video.height > 0,
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        let horizontalChrome = Self.bezel * 2
        let verticalChrome = Self.topBarHeight + Self.bezel
        let aspect = video.width / video.height

        var contentHeight = (visible.height * 0.86).rounded()
        var contentWidth = ((contentHeight - verticalChrome) * aspect + horizontalChrome).rounded()
        if contentWidth > visible.width * 0.86 {
            contentWidth = (visible.width * 0.86).rounded()
            contentHeight = ((contentWidth - horizontalChrome) / aspect + verticalChrome).rounded()
        }
        let size = NSSize(width: contentWidth, height: contentHeight)

        window.contentMinSize = NSSize(width: 200, height: (200 - horizontalChrome) / aspect + verticalChrome)
        window.contentAspectRatio = size

        // Re-centre only on the first fit; after a rotation keep the window
        // where the user put it.
        let firstFit = fittedVideoSize == .zero
        let orientationChanged = (fittedVideoSize.width > fittedVideoSize.height) != (video.width > video.height)
        guard firstFit || orientationChanged else { return }
        fittedVideoSize = video

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if firstFit {
            frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        } else {
            frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: !firstFit)
    }
}

/// A borderless control in the phone window's top bar.
private struct BarButton: View {
    let title: String
    let systemImage: String
    var isOn = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : .white.opacity(isEnabled ? 0.85 : 0.3))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovering && isEnabled ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Hands the hosting NSWindow to SwiftUI code that needs it.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: AccessorView, context: Context) {
        nsView.onWindow = onWindow
    }

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
