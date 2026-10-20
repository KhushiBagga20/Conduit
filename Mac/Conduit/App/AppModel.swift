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
import Observation

@MainActor
final class AppModel {

    static let shared = AppModel()

    let engine = ConduitEngine()
    let router = WorkspaceRouter()

    var store: ConduitStore { engine.store }

    /// Posts the phone's notifications as this Mac's own.
    private lazy var banners = PhoneNotificationBanners { [weak self] in self?.engine }

    private init() {}

    /// Keep this Mac's own notifications in step with the phone's: post what
    /// arrives, and take back what the phone has dismissed.
    func watchNotifications() {
        withObservationTracking { [self] in
            _ = store.notifications
            _ = store.preferences.notificationBanners
        } onChange: { [self] in
            Task { @MainActor in
                banners.update(with: store.notifications, enabled: store.preferences.notificationBanners)
                watchNotifications()
            }
        }
    }

    /// Put the ringing window on screen whenever a phone goes looking for
    /// this Mac, and take it away when the ringing stops. The window belongs
    /// to no scene: it has to appear over other apps, on any Space, whether
    /// or not the workspace is open.
    func watchRinging() {
        // One shared model for the app's lifetime, so it holds itself here.
        withObservationTracking { [self] in
            _ = store.link.ringing
        } onChange: { [self] in
            Task { @MainActor in
                if let ringing = store.link.ringing {
                    RingingPanel.show(phoneName: ringing.phoneName) { [engine] in engine.stopRinging() }
                } else {
                    RingingPanel.hide()
                }
                watchRinging()
            }
        }
    }
}
