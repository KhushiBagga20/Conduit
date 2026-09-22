package com.khushi.conduit.core.link

import java.net.URI

/**
 * Which links Conduit sends and opens — Shared/Protocol/README.md, "Links":
 * web links only (http or https, with a host), at most 2,048 characters.
 * The Mac counterpart is ConduitCore/Link/LinkSharing.swift.
 *
 * The interfaces show a link's site, never the link itself.
 */
object LinkSharing {

    const val MAXIMUM_LENGTH = 2048

    /** [text] as a link Conduit accepts, or null. */
    fun acceptableUrl(text: String): String? {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || trimmed.length > MAXIMUM_LENGTH) return null
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        if (uri.host.isNullOrEmpty()) return null
        return trimmed
    }

    /**
     * The first web link in text another app shared, which is often more
     * than the link: "Look at this https://example.com/page."
     */
    fun firstLink(text: String): String? {
        val candidate = LINK.find(text)?.value ?: return null
        return acceptableUrl(trimTrailingPunctuation(candidate))
    }

    /** The site a link is on, to show instead of the link. */
    fun siteName(url: String): String {
        val host = runCatching { URI(url.trim()).host }.getOrNull()?.lowercase() ?: return "a site"
        return host.removePrefix("www.")
    }

    private val LINK = Regex("""(?i)\bhttps?://[^\s<>"]+""")

    /** A sentence's closing punctuation is not part of the link; a closing bracket is only when it has an opener. */
    private fun trimTrailingPunctuation(link: String): String {
        var end = link.length
        while (end > 0) {
            val last = link[end - 1]
            val drop = when (last) {
                '.', ',', ';', ':', '!', '?', '\'' -> true
                ')' -> link.take(end).count { it == '(' } < link.take(end).count { it == ')' }
                ']' -> link.take(end).count { it == '[' } < link.take(end).count { it == ']' }
                else -> false
            }
            if (!drop) break
            end--
        }
        return link.take(end)
    }
}
