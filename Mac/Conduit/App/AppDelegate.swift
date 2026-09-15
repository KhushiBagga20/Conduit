//
//  AppDelegate.swift
//  Conduit
//
//  App lifecycle rules that SwiftUI scenes cannot express.
//
//  QUITTING
//
//  The workspace is not the app — the menu bar and the connection are. So
//  ⌘Q in the workspace closes the workspace and leaves Conduit running in
//  the menu bar, with the phone still connected. Quitting for real is an
//  explicit choice: Quit Conduit in the menu bar panel, logging out, or a
//  quit request from another app (an Apple event).
//
//  DOCK ICON
//
//  Conduit is a menu bar app (LSUIElement). While one of its windows — the
//  workspace or Settings — is open it becomes a regular app with a Dock icon
//  and a main menu, so it can be switched to like any other app; when the
//  last one closes it goes back to the menu bar.
//

import AppKit
import ConduitCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by "Quit Conduit" in the menu bar panel.
    static var quitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if SnapshotRenderer.runIfRequested() {
            Self.quitRequested = true
            NSApp.terminate(nil)
            return
        }
        #endif
        AppModel.shared.engine.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logout, restart, shutdown and quit requests from other apps arrive
        // as Apple events; ⌘Q from our own menu does not.
        let isAppleEventQuit = NSAppleEventManager.shared().currentAppleEvent?.eventID == kAEQuitApplication
        if Self.quitRequested || isAppleEventQuit {
            return .terminateNow
        }

        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.close()
        }
        explainMenuBarOnce()
        return .terminateCancel
    }

    private func explainMenuBarOnce() {
        let key = "hasExplainedMenuBarQuit"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "Conduit is still running"
        alert.informativeText = "Your phone stays connected in the menu bar. To quit Conduit completely, open it from the menu bar and choose Quit Conduit."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}

/// Switches between menu-bar-only and regular-app presentation.
@MainActor
enum AppPresentation {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowClosed() {
        openWindows = max(openWindows - 1, 0)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
