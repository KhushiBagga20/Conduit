package com.khushi.conduit.link

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.Base64

/**
 * The Macs this phone has paired with. Stored for each: what the spec lists —
 * device ID, public key, name, when it was last seen — plus the addresses it
 * was last reached at, so reconnecting does not depend on discovery.
 */
@Serializable
data class LinkedMac(
    val id: String,
    val name: String,
    /** Base64 X9.63 identity key. */
    val identityKey: String,
    val lastSeen: Long,
    val addresses: List<String> = emptyList(),
    val port: Int = 0,
) {
    val identityKeyBytes: ByteArray get() = Base64.getDecoder().decode(identityKey)
}

class LinkedMacs(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences("link", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(LinkedMac.serializer())

    @Synchronized
    fun all(): List<LinkedMac> =
        prefs.getString(KEY, null)?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() } ?: emptyList()

    @Synchronized
    fun remember(mac: LinkedMac) = save(all().filterNot { it.id == mac.id } + mac)

    @Synchronized
    fun reached(id: String, address: String, port: Int) {
        val mac = all().firstOrNull { it.id == id } ?: return
        remember(mac.copy(lastSeen = System.currentTimeMillis(), addresses = (listOf(address) + mac.addresses).distinct().take(4), port = port))
    }

    @Synchronized
    fun forget(id: String) = save(all().filterNot { it.id == id })

    private fun save(macs: List<LinkedMac>) {
        prefs.edit().putString(KEY, json.encodeToString(serializer, macs)).apply()
    }

    private companion object {
        const val KEY = "macs.v1"
    }
}
