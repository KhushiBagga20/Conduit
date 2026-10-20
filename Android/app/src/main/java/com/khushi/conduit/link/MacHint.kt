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
        remember(context, found)
        LinkHub.update { state -> state.copy(found = (listOf(found) + state.found.filterNot { it.id == found.id }).take(6)) }
        LinkService.poke(context)
        resultData = "noted"
    }

    companion object {
        private const val PREFS = "conduit.machint"

        @Volatile
        private var cached: LinkHub.FoundMac? = null

        /**
         * The last place a Mac said it can be reached. Kept across restarts
         * and updates: MEASURED, a phone that forgot it after an update
         * dialled only stale addresses from another network until the Mac
         * happened to say it again. It holds addresses on the local network
         * and a port — nothing that identifies a person.
         */
        fun latest(context: Context): LinkHub.FoundMac? {
            cached?.let { return it }
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val hosts = prefs.getString("hosts", null)?.split(',')?.filter(String::isNotEmpty).orEmpty()
            val port = prefs.getInt("port", 0)
            if (hosts.isEmpty() || port <= 0) return null
            return LinkHub.FoundMac(prefs.getString("id", null), prefs.getString("name", null) ?: "Mac", hosts, port)
                .also { cached = it }
        }

        private fun remember(context: Context, found: LinkHub.FoundMac) {
            cached = found
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("id", found.id)
                .putString("name", found.name)
                .putString("hosts", found.hosts.joinToString(","))
                .putInt("port", found.port)
                .apply()
        }
    }
}
