package com.khushi.conduit.system

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import com.khushi.conduit.notifications.NotificationRelay

/** System screens Conduit links to. Opening one never crashes the app. */
enum class SystemScreen {
    DEVELOPER_OPTIONS,
    WIFI,
    BATTERY,
    HOTSPOT,
    NOTIFICATION_ACCESS,
    ;

    /** Tried in order, so a phone without the exact screen still lands nearby. */
    private fun candidates(context: Context): List<Intent> = when (this) {
        DEVELOPER_OPTIONS -> listOf(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
        WIFI -> listOf(Intent(Settings.Panel.ACTION_WIFI))
        BATTERY -> listOf(Intent(Intent.ACTION_POWER_USAGE_SUMMARY))
        HOTSPOT -> listOf(Intent("com.android.settings.TETHER_SETTINGS"), Intent(Settings.ACTION_WIRELESS_SETTINGS))
        // Straight to Conduit's own switch where the phone has that screen,
        // and the whole list where it does not.
        NOTIFICATION_ACCESS -> listOf(
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).putExtra(
                Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                ComponentName(context, NotificationRelay::class.java).flattenToString(),
            ),
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS),
        )
    }

    /**
     * The first of the candidates this phone can open, for a notification to
     * launch directly — Android does not let a notification start an activity
     * through anything in between.
     */
    fun intent(context: Context): Intent? =
        candidates(context).firstOrNull { it.resolveActivity(context.packageManager) != null }
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** Returns false when this phone has no such screen. */
    fun open(context: Context): Boolean {
        for (intent in candidates(context)) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: ActivityNotFoundException) {
                continue
            }
        }
        return false
    }
}
