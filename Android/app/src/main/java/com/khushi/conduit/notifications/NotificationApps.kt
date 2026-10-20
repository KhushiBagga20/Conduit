package com.khushi.conduit.notifications

import android.content.Context

/**
 * Which apps' notifications may reach the Mac, and which apps have posted
 * one since Conduit was let in.
 *
 * Only package names and app labels are kept — never a notification, or
 * anything in one.
 */
object NotificationApps {

    /** An app that has posted a notification while Conduit was listening. */
    data class App(val id: String, val name: String, val allowed: Boolean)

    private const val PREFS = "conduit.notifications"
    private const val BLOCKED = "blocked"
    private const val SEEN = "seen"

    fun allowed(context: Context, packageName: String): Boolean = packageName !in blocked(context)

    fun setAllowed(context: Context, packageName: String, allowed: Boolean) {
        val blocked = blocked(context).toMutableSet()
        if (allowed) blocked.remove(packageName) else blocked.add(packageName)
        prefs(context).edit().putStringSet(BLOCKED, blocked).apply()
    }

    /** Remember an app that posted, so it can be switched off by name later. */
    fun remember(context: Context, packageName: String, label: String) {
        val seen = prefs(context).getStringSet(SEEN, emptySet()).orEmpty()
        val entry = "$packageName\u0000$label"
        if (entry in seen) return
        // One entry per package: a renamed app replaces its old label.
        val kept = seen.filterNot { it.substringBefore('\u0000') == packageName }.toMutableSet()
        kept.add(entry)
        prefs(context).edit().putStringSet(SEEN, kept).apply()
    }

    fun apps(context: Context): List<App> {
        val blocked = blocked(context)
        return prefs(context).getStringSet(SEEN, emptySet()).orEmpty()
            .map { entry ->
                val id = entry.substringBefore('\u0000')
                App(id = id, name = entry.substringAfter('\u0000', id), allowed = id !in blocked)
            }
            .sortedBy { it.name.lowercase() }
    }

    private fun blocked(context: Context): Set<String> =
        prefs(context).getStringSet(BLOCKED, emptySet()).orEmpty()

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
