//
//  ConduitApp.swift
//  Conduit
//
//  One app, two Mac interfaces, one connection owner:
//
//    MenuBarExtra  — always present; status, quick actions, activity
//    Window        — the workspace; opened on demand, closing it changes
//                    nothing about the connection
//    Window        — the phone screen on its own, while mirroring
//    Settings      — the standard Settings window (⌘,)
//

import ConduitState
import SwiftUI

@main
struct ConduitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(model.store)
                .environment(model.router)
        } label: {
            MenuBarLabel(store: model.store)
        }
        .menuBarExtraStyle(.window)

        Window("Conduit", id: WorkspaceRouter.windowID) {
            WorkspaceView()
                .environment(model.store)
                .environment(model.router)
        }
        .defaultSize(width: 980, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommands(router: model.router)
        }

        Window("Phone", id: WorkspaceRouter.phoneWindowID) {
            PhoneWindowView()
                .environment(model.store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 860)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsWindow()
                .environment(model.store)
                .onAppear { AppPresentation.windowOpened() }
                .onDisappear { AppPresentation.windowClosed() }
        }
    }
}
