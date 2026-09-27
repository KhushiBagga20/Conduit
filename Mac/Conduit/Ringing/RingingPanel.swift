//
//  RingingPanel.swift
//  Conduit
//
//  What a phone looking for this Mac puts on screen: a floating window that
//  appears over whatever is open, on any Space, without stealing focus from
//  what the person is doing. It is the half of find-my-Mac that works on a
//  muted Mac.
//

import AppKit
import SwiftUI

@MainActor
enum RingingPanel {

    private static var panel: NSPanel?

    static func show(phoneName: String, stop: @escaping () -> Void) {
        hide()

        let view = NSHostingView(rootView: RingingView(phoneName: phoneName, stop: stop))
        view.frame.size = view.fittingSize

        // A non-activating panel: clicking Stop does not pull the person out
        // of the app they are in.
        let panel = NSPanel(contentRect: view.frame,
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = view
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RingingView: View {
    let phoneName: String
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text("\(phoneName) is looking for this Mac")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Conduit is ringing at this Mac's own volume. It stops by itself after two minutes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Stop", action: stop)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .frame(width: 340)
    }
}
