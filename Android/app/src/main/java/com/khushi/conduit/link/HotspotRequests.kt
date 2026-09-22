package com.khushi.conduit.link

import android.content.Context

/** Whether a paired Mac may ask this phone for its hotspot. On unless turned off. */
object HotspotRequests {

    private const val KEY = "hotspotRequests"

    fun enabled(context: Context): Boolean =
        context.getSharedPreferences("link", Context.MODE_PRIVATE).getBoolean(KEY, true)

    fun setEnabled(context: Context, on: Boolean) {
        context.getSharedPreferences("link", Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
        LinkService.refreshBeacon()
    }
}
