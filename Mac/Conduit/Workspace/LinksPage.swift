//
//  LinksPage.swift
//  Conduit
//
//  Link Sharing: send the web link on this Mac's clipboard to the linked
//  phone, and open the links it shares. Only site names appear here; full
//  links are never kept or logged.
//

import ConduitDesign
import ConduitProtocol
import ConduitState
import SwiftUI

struct LinksPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router

    var body: some View {
        Group {
            if store.link.phones.isEmpty {
                ContentUnavailableView {
                    Label("Link Sharing", systemImage: "link")
                } description: {
                    Text("Links travel over Conduit Link. Link a phone first: in Conduit for Android, choose Add Mac.")
                } actions: {
                    Button("Open Devices") { router.section = .devices }
                }
            } else {
                form
            }
        }
        .navigationTitle("Link Sharing")
    }

    private var form: some View {
        let phone = store.link.phones.first(where: \.isConnected)

        return Form {
            Section {
                LabeledContent {
                    Button("Send Link") { store.commands?.sendLinkToPhone() }
                        .disabled(phone == nil || store.link.linkSend.isSending)
                } label: {
                    Text("Send the link on the clipboard")
                    Text(store.link.linkSend.detail ?? (phone.map {
                        "Copy a web link on this Mac, then send it to \($0.name). The phone shows it as a notification."
                    } ?? LinkSendStatus.noPhoneConnected.detail ?? ""))
                }
            } header: {
                Text("To the Phone")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { store.preferences.openLinksFromPhone },
                    set: { value in store.commands?.updatePreferences { $0.openLinksFromPhone = value } })) {
                    Text("Open links from the phone")
                    Text("On the phone, share a link and choose Conduit. It opens in this Mac's default browser.")
                }
            } header: {
                Text("From the Phone")
            } footer: {
                Text("Only web links, starting with http or https, are sent or opened. Activity keeps the site's name, never the link.")
            }

            let recent = Array(store.activity.filter { $0.kind == .linkReceived }.prefix(5))
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent) { event in
                        LabeledContent {
                            Text(event.date, format: .dateTime.hour().minute())
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } label: {
                            Text(event.title)
                            if let site = event.detail { Text(site) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
