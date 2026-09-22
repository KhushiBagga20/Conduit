//
//  LinkSharing.swift
//  ConduitCore
//
//  Which links Conduit will pass between the phone and the Mac —
//  Shared/Protocol/README.md §6, "Links". Only web links: a paired device
//  must not be able to use a link to launch other apps on this Mac.
//

import Foundation

nonisolated enum LinkSharing {

    static let maximumLength = 2048

    /// The link as a URL Conduit may open, or nil when it is not one.
    static func acceptableURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// What activity may show about a link: its site, never the whole address.
    static func siteName(of url: URL) -> String {
        let host = url.host?.lowercased() ?? "a site"
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
