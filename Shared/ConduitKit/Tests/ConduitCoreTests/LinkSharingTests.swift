//
//  LinkSharingTests.swift
//  ConduitCoreTests
//
//  Which links Conduit opens, and what it shows about them.
//

import Foundation
import Testing
@testable import ConduitCore

@Suite("Link sharing")
struct LinkSharingTests {

    @Test("web links are accepted")
    func acceptsWebLinks() {
        #expect(LinkSharing.acceptableURL("https://example.com/a?b=c")?.host == "example.com")
        #expect(LinkSharing.acceptableURL("  http://example.com  ") != nil)
        #expect(LinkSharing.acceptableURL("HTTPS://Example.com") != nil)
    }

    @Test("anything that could launch something else is refused")
    func refusesEverythingElse() {
        #expect(LinkSharing.acceptableURL("") == nil)
        #expect(LinkSharing.acceptableURL("file:///etc/hosts") == nil)
        #expect(LinkSharing.acceptableURL("javascript:alert(1)") == nil)
        #expect(LinkSharing.acceptableURL("ssh://example.com") == nil)
        #expect(LinkSharing.acceptableURL("mailto:someone@example.com") == nil)
        #expect(LinkSharing.acceptableURL("https://") == nil)
        #expect(LinkSharing.acceptableURL("just some words") == nil)
        #expect(LinkSharing.acceptableURL("https://example.com/" + String(repeating: "a", count: 2048)) == nil)
    }

    @Test("activity names the site, not the address")
    func siteNames() throws {
        #expect(LinkSharing.siteName(of: try #require(URL(string: "https://www.example.com/private/path?token=1"))) == "example.com")
        #expect(LinkSharing.siteName(of: try #require(URL(string: "http://News.Example.org"))) == "news.example.org")
    }
}
