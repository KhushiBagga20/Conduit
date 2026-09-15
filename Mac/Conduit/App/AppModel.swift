//
//  AppModel.swift
//  Conduit
//
//  The composition root. The only file in the app that creates the
//  connection owner — and so the only place that imports ConduitCore.
//
//  Everything else (the menu bar and the workspace) receives a ConduitStore
//  and talks through ConduitCommands. When the owner moves into a helper
//  process, this file is what changes.
//

import ConduitCore
import ConduitState

@MainActor
final class AppModel {

    static let shared = AppModel()

    let engine = ConduitEngine()
    let router = WorkspaceRouter()

    var store: ConduitStore { engine.store }

    private init() {}
}
