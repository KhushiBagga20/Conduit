package com.khushi.conduit.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * Finds Macs advertising Conduit Link over Bonjour. Resolving is done one
 * service at a time: NsdManager refuses a second resolve while one is running.
 */
class MacDiscovery(context: Context, private val onChange: () -> Unit) {

    private val nsd = context.getSystemService(NsdManager::class.java)
    private val resolved = ConcurrentHashMap<String, LinkHub.FoundMac>()
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var discovering = false

    val results: List<LinkHub.FoundMac> get() = resolved.values.toList()

    private val discovery = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.w(TAG, "discovery failed to start: $errorCode")
            synchronized(this@MacDiscovery) { discovering = false }
        }
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

        override fun onServiceFound(info: NsdServiceInfo) {
            synchronized(this@MacDiscovery) { queue.addLast(info) }
            resolveNext()
        }

        override fun onServiceLost(info: NsdServiceInfo) {
            if (resolved.remove(info.serviceName) != null) onChange()
        }
    }

    @Synchronized
    fun start() {
        if (discovering) return
        discovering = true
        runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery) }
            .onFailure { discovering = false }
    }

    @Synchronized
    fun stop() {
        if (!discovering) return
        discovering = false
        runCatching { nsd.stopServiceDiscovery(discovery) }
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        val next = synchronized(this) {
            if (resolving) return
            queue.removeFirstOrNull()?.also { resolving = true }
        } ?: return

        nsd.resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = done()

            override fun onServiceResolved(info: NsdServiceInfo) {
                val host = info.host?.hostAddress
                if (host != null && info.port > 0) {
                    resolved[info.serviceName] = LinkHub.FoundMac(
                        id = info.attributes["id"]?.decodeToString(),
                        name = info.serviceName,
                        hosts = listOf(host),
                        port = info.port,
                    )
                    onChange()
                }
                done()
            }

            private fun done() {
                synchronized(this@MacDiscovery) { resolving = false }
                resolveNext()
            }
        })
    }

    private companion object {
        const val TAG = "ConduitLink"
        const val SERVICE_TYPE = "_conduit._tcp"
    }
}
