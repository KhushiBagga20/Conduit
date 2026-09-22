package com.khushi.conduit.core.link

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The same rules as the Mac's LinkSharingTests. */
class LinkSharingTest {

    @Test
    fun acceptsWebLinks() {
        assertEquals("https://example.com/a?b=c", LinkSharing.acceptableUrl("https://example.com/a?b=c"))
        assertEquals("http://example.com", LinkSharing.acceptableUrl("  http://example.com \n"))
        assertEquals("HTTPS://EXAMPLE.COM", LinkSharing.acceptableUrl("HTTPS://EXAMPLE.COM"))
    }

    @Test
    fun refusesEverythingElse() {
        listOf(
            "file:///etc/hosts", "javascript:alert(1)", "ssh://example.com", "mailto:someone@example.com",
            "https://", "example.com", "just some words", "", "https://example.com/" + "a".repeat(LinkSharing.MAXIMUM_LENGTH),
        ).forEach { assertNull(it, LinkSharing.acceptableUrl(it)) }
    }

    @Test
    fun findsTheLinkInSharedText() {
        assertEquals("https://example.com/page", LinkSharing.firstLink("Look at this https://example.com/page."))
        assertEquals("https://example.com/a", LinkSharing.firstLink("https://example.com/a, and https://example.org/b"))
        assertEquals("https://en.wikipedia.org/wiki/Swift_(programming_language)",
            LinkSharing.firstLink("(see https://en.wikipedia.org/wiki/Swift_(programming_language))"))
        assertEquals("https://youtu.be/abc?t=4", LinkSharing.firstLink("https://youtu.be/abc?t=4"))
        assertNull(LinkSharing.firstLink("no link here"))
        assertNull(LinkSharing.firstLink("javascript:alert(1) file:///etc/hosts"))
    }

    @Test
    fun namesTheSiteOnly() {
        assertEquals("example.com", LinkSharing.siteName("https://www.example.com/private/path?token=1"))
        assertEquals("news.example.org", LinkSharing.siteName("http://News.Example.org"))
        assertEquals("a site", LinkSharing.siteName("not a link"))
    }
}
