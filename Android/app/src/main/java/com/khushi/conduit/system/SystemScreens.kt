package com.khushi.conduit.system

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings

/** System screens Conduit links to. Opening one never crashes the app. */
enum class SystemScreen(private val action: String) {
    DEVELOPER_OPTIONS(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS),
    WIFI(Settings.Panel.ACTION_WIFI),
    BATTERY(Intent.ACTION_POWER_USAGE_SUMMARY),
    ;

    /** Returns false when this phone has no such screen. */
    fun open(context: Context): Boolean = try {
        context.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}
