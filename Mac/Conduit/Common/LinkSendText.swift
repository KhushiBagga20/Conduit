//
//  LinkSendText.swift
//  Conduit
//
//  How the interfaces describe sending a link to the phone. Only the site's
//  name appears, never the link.
//

import ConduitState
import Foundation

extension LinkSendStatus {

    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }

    /// A word or two for the menu bar.
    var shortStatus: String? {
        switch self {
        case .idle: nil
        case .sending: "Sending…"
        case .sent: "Sent"
        case .noLinkOnClipboard: "Copy a link first"
        case .noPhoneConnected: "Not connected"
        case .failed: "Failed"
        }
    }

    var detail: String? {
        switch self {
        case .idle: nil
        case .sending(let site): "Sending \(site)…"
        case .sent(let site, let phone): "Sent \(site) to \(phone). Tap the notification on the phone to open it."
        case .noLinkOnClipboard: "The clipboard has no web link. Copy one that starts with http or https, then send it."
        case .noPhoneConnected: "No linked phone is connected. Open Conduit for Android, on a network this Mac shares."
        case .failed(let message): message
        }
    }
}
