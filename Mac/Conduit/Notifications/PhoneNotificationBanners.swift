//
//  PhoneNotificationBanners.swift
//  Conduit
//
//  Shows the phone's notifications as this Mac's own, which is the whole
//  point of the feature: nobody watches a list in a window. Conduit's own
//  alerts — this Mac leaving the phone's hotspot — go out the same way.
//
//  macOS asks for permission the first time one is posted, not at launch —
//  a prompt before anything has happened is a prompt with no context.
//

import AppKit
import ConduitProtocol
import ConduitState
import UserNotifications

@MainActor
final class PhoneNotificationBanners: NSObject {

    private static let category = "phone-notification"
    private static let alertCategory = "conduit-alert"
    private static let dismissAction = "dismiss"
    private static let openAction = "open"

    private let commands: () -> (any ConduitCommands)?
    /// Keys already shown, so a re-sync does not ring the same one twice.
    private var shown: Set<String> = []
    private var askedForPermission = false

    init(commands: @escaping () -> (any ConduitCommands)?) {
        self.commands = commands
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Self.openAction, title: "Open on Phone"),
                UNNotificationAction(identifier: Self.dismissAction, title: "Dismiss"),
            ], intentIdentifiers: [], options: []),
        ])
    }

    /// Post what is new, and take back what the phone has dismissed.
    func update(with notifications: [PhoneNotification], enabled: Bool) {
        let keys = Set(notifications.map(\.key))
        let gone = shown.subtracting(keys)
        if !gone.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(gone))
            shown.subtract(gone)
        }

        guard enabled else { return }
        let fresh = notifications.filter { !shown.contains($0.key) }
        guard !fresh.isEmpty else { return }
        shown.formUnion(fresh.map(\.key))

        Task { @MainActor in
            guard await allowedToShow() else { return }
            for notification in fresh { post(notification) }
        }
    }

    /// macOS is asked once, the first time there is something to show.
    private func allowedToShow() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            guard !askedForPermission else { return false }
            askedForPermission = true
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    /// One of Conduit's own: this Mac left the phone's hotspot, say. It
    /// replaces the last of its kind rather than piling up.
    func post(_ alert: ConduitAlert) {
        Task { @MainActor in
            guard await allowedToShow() else { return }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.categoryIdentifier = Self.alertCategory
            content.userInfo = ["action": alert.action == .openWiFiSettings ? "wifi" : ""]
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: Self.alertCategory, content: content, trigger: nil))
        }
    }

    private func post(_ notification: PhoneNotification) {
        let content = UNMutableNotificationContent()
        let title = notification.title.flatMap { $0.isEmpty ? nil : $0 }
        if notification.redacted {
            content.title = notification.appName
            content.body = "Private — the phone kept the contents"
        } else {
            // The app's name leads when there is no title of its own, and
            // sits underneath when there is.
            content.title = title ?? notification.appName
            content.subtitle = title == nil ? "" : notification.appName
            content.body = notification.text ?? ""
        }
        content.categoryIdentifier = Self.category
        content.userInfo = ["key": notification.key]
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notification.key, content: content, trigger: nil))
    }
}

extension PhoneNotificationBanners: UNUserNotificationCenterDelegate {

    /// Show them even while Conduit is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        if content.categoryIdentifier == Self.alertCategory {
            if content.userInfo["action"] as? String == "wifi",
               let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            return
        }
        let key = content.userInfo["key"] as? String
        await MainActor.run {
            guard let key else { return }
            switch response.actionIdentifier {
            case Self.openAction, UNNotificationDefaultActionIdentifier:
                commands()?.openNotification(key: key)
            case Self.dismissAction:
                commands()?.dismissNotification(key: key)
            default:
                break
            }
        }
    }
}
