package com.khushi.conduit.link

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Where a Mac can be reached, told to the phone over adb by Conduit for Mac:
 *
 *     am broadcast -n com.khushi.conduit/.link.MacHint \
 *         --es id <device ID> --es name <name> --es hosts <a,b,c> --ei port 47384
 *
 * This finds the Mac when Bonjour cannot — on a phone's own hotspot, or when
 * macOS has not yet allowed Conduit to advertise itself. Only senders holding
 * WRITE_SECURE_SETTINGS, such as the adb shell, can deliver it, and it only
 * says where to knock: the handshake still proves who answers.
 */
class MacHint : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val hosts = intent.getStringExtra("hosts")?.split(',')?.map(String::trim)?.filter(String::isNotEmpty).orEmpty()
        val port = intent.getIntExtra("port", 0)
        if (hosts.isEmpty() || port <= 0) return

        val found = LinkHub.FoundMac(
            id = intent.getStringExtra("id"),
            name = intent.getStringExtra("name") ?: "Mac",
            hosts = hosts,
            port = port,
        )
        latest = found
        LinkHub.update { state -> state.copy(found = (listOf(found) + state.found.filterNot { it.id == found.id }).take(6)) }
        LinkService.poke(context)
        resultData = "noted"
    }

    companion object {
        @Volatile
        var latest: LinkHub.FoundMac? = null
            private set
    }
}
