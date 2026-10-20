package com.khushi.conduit.link

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings Conduit Link back after the phone restarts or Conduit is updated,
 * so a paired Mac is reachable without opening the app first. Android lets
 * an app start its foreground service from exactly these two moments. With
 * no paired Mac it does nothing.
 */
class LinkStarter : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> LinkService.ensureRunning(context)
        }
    }
}
