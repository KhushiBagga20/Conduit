package com.khushi.conduit.link

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * "Send clipboard to Mac" in Quick Settings: one tap from anywhere, since
 * Android lets no app read the clipboard in the background. A locked phone
 * is unlocked first — the clipboard is the person's, not the lock screen's.
 */
class ClipboardTileService : TileService() {

    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        if (isLocked) unlockAndRun(::send) else send()
    }

    // Android 12 and 13 have only the Intent form; 14 added the PendingIntent one.
    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun send() {
        val intent = Intent(this, SendClipboardActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
