package com.khushi.conduit.system

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings

/** System screens Conduit links to. Opening one never crashes the app. */
enum class SystemScreen {
    DEVELOPER_OPTIONS,
    WIFI,
    BATTERY,
    HOTSPOT,
    ;

    /** Tried in order, so a phone without the exact screen still lands nearby. */
    private fun candidates(): List<Intent> = when (this) {
        DEVELOPER_OPTIONS -> listOf(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
        WIFI -> listOf(Intent(Settings.Panel.ACTION_WIFI))
        BATTERY -> listOf(Intent(Intent.ACTION_POWER_USAGE_SUMMARY))
        HOTSPOT -> listOf(Intent("com.android.settings.TETHER_SETTINGS"), Intent(Settings.ACTION_WIRELESS_SETTINGS))
    }

    /**
     * The first of the candidates this phone can open, for a notification to
     * launch directly — Android does not let a notification start an activity
     * through anything in between.
     */
    fun intent(context: Context): Intent? =
        candidates().firstOrNull { it.resolveActivity(context.packageManager) != null }
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** Returns false when this phone has no such screen. */
    fun open(context: Context): Boolean {
        for (intent in candidates()) {
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
