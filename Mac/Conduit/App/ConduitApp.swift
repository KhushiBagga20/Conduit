//
//  ConduitApp.swift
//  Conduit
//
//  One app, two Mac interfaces, one connection owner:
//
//    MenuBarExtra  — always present; status, quick actions, activity
//    Window        — the workspace; opened on demand, closing it changes
//                    nothing about the connection
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
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            WorkspaceCommands(router: model.router)
        }
    }
}
