//
//  NotificationsPage.swift
//  Conduit
//
//  The phone's notifications, on the Mac. They are the phone's: dismissing
//  one here dismisses it there, and when the phone goes, the list goes with
//  it. Conduit writes none of them down.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct NotificationsPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router

    var body: some View {
        Group {
            if store.link.phones.isEmpty {
                ContentUnavailableView {
                    Label("Notifications", systemImage: "bell")
                } description: {
                    Text("Notifications travel over Conduit Link. Link a phone first: in Conduit for Android, choose Add Mac.")
                } actions: {
                    Button("Open Devices") { router.section = .devices }
                }
            } else {
                form
            }
        }
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem {
                Button { store.commands?.refreshNotifications() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Ask the phone what it is showing")
            }
        }
        .task { store.commands?.refreshNotifications() }
    }

    private var form: some View {
        Form {
            if let refusal = store.link.notificationsRefusal, !store.link.notificationsReady {
                Section {
                    LabeledContent {
                        Button("Check Again") { store.commands?.refreshNotifications() }
                    } label: {
                        Text("The phone is not sending notifications")
                        Text(refusal)
                    }
                } header: {
                    Text("On the Phone")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { store.preferences.notificationBanners },
                    set: { value in store.commands?.updatePreferences { $0.notificationBanners = value } })) {
                    Text("Show them on this Mac as they arrive")
                    Text("Each one appears as a notification here, with Dismiss and Open on Phone. macOS asks for permission the first time.")
                }
            } header: {
                Text("On This Mac")
            }

            Section {
                if store.notifications.isEmpty {
                    Text(store.link.notificationsReady
                         ? "Nothing on the phone right now."
                         : "Notifications from the phone will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.notifications) { notification in
                    row(notification)
                }
            } header: {
                HStack {
                    Text("Showing on the Phone")
                    Spacer()
                    if !store.notifications.isEmpty {
                        Button("Clear List") { store.commands?.clearNotifications() }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                }
            } footer: {
                Text("Dismissing one here dismisses it on the phone. Which apps may send is chosen on the phone, in Conduit → Settings → Notifications.")
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ notification: PhoneNotification) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Open") { store.commands?.openNotification(key: notification.key) }
                    .help("Open it on the phone")
                if notification.clearable {
                    Button("Dismiss") { store.commands?.dismissNotification(key: notification.key) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(notification.appName)
                Text(Date(timeIntervalSince1970: Double(notification.postedAt) / 1000),
                     format: .dateTime.hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if notification.redacted {
                Text("Private — the phone kept the contents")
            } else {
                if let title = notification.title, !title.isEmpty { Text(title) }
                if let text = notification.text, !text.isEmpty { Text(text) }
            }
        }
    }
}
