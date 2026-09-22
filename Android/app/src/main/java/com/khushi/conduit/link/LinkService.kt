package com.khushi.conduit.link

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log
import com.khushi.conduit.MainActivity
import com.khushi.conduit.R
import com.khushi.conduit.core.link.HotspotRequestGate
import com.khushi.conduit.core.protocol.ActionName
import com.khushi.conduit.core.protocol.DeviceInfo
import com.khushi.conduit.core.protocol.DeviceSnapshot
import com.khushi.conduit.core.protocol.Envelope
import com.khushi.conduit.core.protocol.EnvelopeKind
import com.khushi.conduit.core.protocol.ErrorCode
import com.khushi.conduit.core.protocol.EventName
import com.khushi.conduit.core.protocol.HandshakeIntent
import com.khushi.conduit.core.protocol.LinkSessionInfo
import com.khushi.conduit.core.protocol.Outcome
import com.khushi.conduit.core.protocol.ProtocolError
import com.khushi.conduit.system.SystemScreen
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.Base64
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Keeps this phone linked to the Macs it paired with, and runs pairing when
 * the person adds one.
 *
 * A foreground service, so the link does not depend on a visible screen: the
 * phone dials the Mac — it is the one that roams — trying the address the Mac
 * last told it over adb, what Bonjour finds, and where it was reached before,
 * with backoff when nothing answers.
 */
class LinkService : Service() {

    private lateinit var macs: LinkedMacs
    private lateinit var discovery: MacDiscovery
    private lateinit var beacon: HotspotBeacon
    private val hotspotGate = HotspotRequestGate()
    private var worker: Thread? = null
    @Volatile private var running = false
    private val wake = Object()

    @Volatile private var connection: LinkConnection? = null
    @Volatile private var pendingPair: LinkHub.FoundMac? = null
    private var heartbeat: ScheduledExecutorService? = null

    /** A new epoch each time this process starts, as the spec asks for events. */
    private val epoch = UUID.randomUUID().toString()
    private val seq = AtomicLong(0)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        macs = LinkedMacs(this)
        discovery = MacDiscovery(this) { publishFound() }
        beacon = HotspotBeacon(this, ::hotspotRequested)
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(CHANNEL, "Conduit Link", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows while this phone is linked to a Mac, or looking for one."
            },
        )
        notifications.createNotificationChannel(
            NotificationChannel(HOTSPOT_CHANNEL, "Hotspot requests", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "When your linked Mac is offline and asks for this phone's hotspot."
            },
        )
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, notification("Looking for your Mac"),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)

        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PAIR -> {
                val hosts = intent.getStringArrayListExtra(EXTRA_HOSTS).orEmpty()
                val port = intent.getIntExtra(EXTRA_PORT, 0)
                if (hosts.isNotEmpty() && port > 0) {
                    pendingPair = LinkHub.FoundMac(intent.getStringExtra(EXTRA_ID), intent.getStringExtra(EXTRA_NAME) ?: "Mac", hosts, port)
                    connection?.close()
                }
            }
        }

        discovery.start()
        publishLinked()
        updateBeacon()
        if (worker == null) {
            running = true
            worker = Thread(::loop, "conduit-link").also { it.start() }
        }
        wakeUp()
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        beacon.stop()
        connection?.close()
        stopHeartbeat()
        discovery.stop()
        wakeUp()
        instance = null
        LinkHub.update { it.copy(status = LinkHub.Status.Off, connectedId = null, pairing = null) }
        super.onDestroy()
    }

    // The loop

    private fun loop() {
        var misses = 0
        while (running) {
            val pair = pendingPair
            if (pair != null) {
                pendingPair = null
                LinkHub.update { it.copy(status = LinkHub.Status.Connecting(pair.name)) }
                if (!pair.hosts.any { host -> running && dial(host, pair.port, HandshakeIntent.PAIR, pair.name, null) }) {
                    LinkHub.update { it.copy(status = LinkHub.Status.Failed("Couldn't reach ${pair.name}."), pairing = null) }
                }
                continue
            }

            val linked = macs.all()
            if (linked.isEmpty() && !LinkHub.state.value.adding) {
                stopSelf()
                return
            }

            var reached = false
            for (mac in linked) {
                if (!running || pendingPair != null) break
                LinkHub.update { it.copy(status = LinkHub.Status.Looking) }
                for ((host, port) in candidates(mac)) {
                    if (!running || pendingPair != null) break
                    if (dial(host, port, HandshakeIntent.CONNECT, mac.name, mac)) reached = true
                }
            }
            misses = if (reached) 0 else misses + 1
            if (running && pendingPair == null) {
                LinkHub.update { state ->
                    state.copy(status = if (linked.isEmpty()) LinkHub.Status.Off else LinkHub.Status.Looking)
                }
                notify(if (linked.isEmpty()) "Ready to add a Mac" else "Looking for ${linked.first().name}")
                sleep(backoffMillis(misses))
            }
        }
    }

    /** Where to try a paired Mac: what it told us over adb, then Bonjour, then where it was before. */
    private fun candidates(mac: LinkedMac): List<Pair<String, Int>> {
        val hinted = MacHint.latest?.takeIf { it.id == mac.id }?.let { hint -> hint.hosts.map { it to hint.port } }.orEmpty()
        val nearby = discovery.results.filter { it.id == mac.id }.flatMap { found -> found.hosts.map { it to found.port } }
        val before = if (mac.port > 0) mac.addresses.map { it to mac.port } else emptyList()
        return (hinted + nearby + before).distinct()
    }

    /** Connect and serve until the connection ends. True if it got as far as ready. */
    private fun dial(host: String, port: Int, intent: HandshakeIntent, name: String, known: LinkedMac?): Boolean {
        var reachedReady = false
        val link = LinkConnection(
            signer = KeystoreSigner.get(),
            device = DeviceSnapshots.device(this, KeystoreSigner.get().deviceId),
            intent = intent,
            expectedMacKey = known?.identityKeyBytes,
            listener = object : LinkConnection.Listener {
                override fun onPairingCode(code: String, mac: DeviceInfo) {
                    LinkHub.update { it.copy(pairing = LinkHub.PairingPrompt(code, mac.name)) }
                }

                override fun onReady(connection: LinkConnection, mac: DeviceInfo, macKey: ByteArray, session: LinkSessionInfo) {
                    reachedReady = true
                    if (intent == HandshakeIntent.PAIR) {
                        macs.remember(LinkedMac(mac.id, mac.name, Base64.getEncoder().encodeToString(macKey),
                            System.currentTimeMillis(), listOf(host), port))
                    } else {
                        macs.reached(mac.id, host, port)
                    }
                    publishLinked()
                    LinkHub.update {
                        it.copy(status = LinkHub.Status.Connected(mac.name), connectedId = mac.id, pairing = null, adding = false)
                    }
                    notify("Linked to ${mac.name}")
                    connection.useHeartbeat(session.heartbeatSeconds)
                    startHeartbeat(connection, session.heartbeatSeconds)
                    sendSnapshot(connection)
                    Log.i(TAG, "linked")
                }

                override fun onEnvelope(connection: LinkConnection, envelope: Envelope) = handle(connection, envelope)

                override fun onClosed(error: ProtocolError?) {
                    stopHeartbeat()
                    LinkHub.update { state ->
                        state.copy(
                            connectedId = null,
                            pairing = null,
                            status = if (error != null && intent == HandshakeIntent.PAIR) {
                                LinkHub.Status.Failed(error.message)
                            } else {
                                state.status
                            },
                        )
                    }
                }
            },
        )
        connection = link
        link.run(host, port)
        connection = null
        return reachedReady
    }

    // Messages

    private fun handle(connection: LinkConnection, envelope: Envelope) {
        when (val kind = envelope.kind) {
            is EnvelopeKind.Command -> when (kind.action) {
                ActionName.SESSION_PING -> connection.send(Envelope(EnvelopeKind.Response(kind.requestId, Outcome.Success), envelope.payload))
                ActionName.STATE_SYNC -> sendSnapshot(connection)
                else -> connection.send(Envelope(EnvelopeKind.Response(kind.requestId, Outcome.Failure(
                    ProtocolError(ErrorCode.UNSUPPORTED, "This version of Conduit for Android does not do that yet."),
                ))))
            }
            is EnvelopeKind.Response, is EnvelopeKind.Event -> Unit
        }
    }

    private fun sendSnapshot(connection: LinkConnection) {
        val snapshot = DeviceSnapshots.snapshot(this, KeystoreSigner.get().deviceId)
        val payload = Json.encodeToJsonElement(DeviceSnapshot.serializer(), snapshot).jsonObject
        connection.send(Envelope(EnvelopeKind.Event(EventName.DEVICE_SNAPSHOT, epoch, seq.incrementAndGet(),
            System.currentTimeMillis()), payload))
    }

    private fun startHeartbeat(connection: LinkConnection, seconds: Int) {
        stopHeartbeat()
        val interval = seconds.coerceIn(5, 60).toLong()
        heartbeat = Executors.newSingleThreadScheduledExecutor().also { timer ->
            timer.scheduleWithFixedDelay({
                connection.send(Envelope(EnvelopeKind.Command(UUID.randomUUID().toString(), ActionName.SESSION_PING),
                    buildJsonObject { put("sentAt", System.currentTimeMillis()) }))
            }, interval, interval, TimeUnit.SECONDS)
        }
    }

    private fun stopHeartbeat() {
        heartbeat?.shutdownNow()
        heartbeat = null
    }

    // Hotspot on request

    /**
     * Listen for a paired Mac asking for the hotspot: with a paired Mac, the
     * person's say-so and Android's Nearby devices permission. MEASURED in
     * design: waiting for the link to drop first raced the Mac, which asks
     * five seconds after losing its network while this phone can take a
     * heartbeat or more to notice — so it listens whenever it may be asked.
     */
    private fun updateBeacon() {
        val wanted = HotspotRequests.enabled(this) && macs.all().isNotEmpty()
        if (wanted) beacon.start() else beacon.stop()
        LinkHub.update { it.copy(hotspotRequestsReady = wanted && beacon.canRun) }
    }

    private fun hotspotRequested(request: ByteArray) {
        val paired = macs.all()
        val macId = hotspotGate.check(request, KeystoreSigner.get().deviceId,
            paired.associate { it.id to it.identityKeyBytes }) ?: return
        val mac = paired.first { it.id == macId }
        Log.i(TAG, "a paired Mac asked for the hotspot")

        // Android does not let an app turn the hotspot on; the notification
        // opens the switch, and the Mac rejoins the hotspot it remembers.
        val settings = SystemScreen.HOTSPOT.intent(this) ?: return
        val open = PendingIntent.getActivity(this, 2, settings, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        getSystemService(NotificationManager::class.java).notify(HOTSPOT_NOTIFICATION_ID,
            Notification.Builder(this, HOTSPOT_CHANNEL)
                .setSmallIcon(R.drawable.ic_link)
                .setContentTitle("${mac.name} wants your hotspot")
                .setContentText("Tap to turn Mobile Hotspot on. Your Mac joins it by itself.")
                .setContentIntent(open)
                .addAction(Notification.Action.Builder(null, "Turn on", open).build())
                .setAutoCancel(true)
                .setTimeoutAfter(2 * 60_000L)
                .build())
    }

    // Plumbing

    private fun publishLinked() = LinkHub.update { it.copy(linked = macs.all().sortedByDescending(LinkedMac::lastSeen)) }

    private fun publishFound() = LinkHub.update { state ->
        val hint = MacHint.latest
        state.copy(found = (listOfNotNull(hint) + discovery.results).distinctBy { it.id ?: it.hosts.first() })
    }

    private fun backoffMillis(misses: Int): Long = (2_000L shl (misses - 1).coerceIn(0, 4)).coerceAtMost(30_000L)

    private fun sleep(millis: Long) = synchronized(wake) { runCatching { wake.wait(millis) } }

    private fun wakeUp() = synchronized(wake) { wake.notifyAll() }

    private fun notify(text: String) =
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))

    private fun notification(text: String): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_link)
            .setContentTitle("Conduit")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "ConduitLink"
        private const val CHANNEL = "link"
        private const val NOTIFICATION_ID = 7
        private const val HOTSPOT_CHANNEL = "hotspot"
        private const val HOTSPOT_NOTIFICATION_ID = 8
        private const val ACTION_PAIR = "com.khushi.conduit.link.PAIR"
        private const val ACTION_STOP = "com.khushi.conduit.link.STOP"
        private const val EXTRA_ID = "id"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_HOSTS = "hosts"
        private const val EXTRA_PORT = "port"

        @Volatile
        private var instance: LinkService? = null

        /** Look for Macs to add, and keep the link running meanwhile. */
        fun startAdding(context: Context) {
            LinkHub.update { it.copy(adding = true, status = LinkHub.Status.Looking) }
            context.startForegroundService(Intent(context, LinkService::class.java))
        }

        fun stopAdding(context: Context) {
            LinkHub.update { it.copy(adding = false) }
            instance?.wakeUp()
        }

        fun pair(context: Context, mac: LinkHub.FoundMac) {
            context.startForegroundService(Intent(context, LinkService::class.java).setAction(ACTION_PAIR)
                .putExtra(EXTRA_ID, mac.id).putExtra(EXTRA_NAME, mac.name)
                .putStringArrayListExtra(EXTRA_HOSTS, ArrayList(mac.hosts)).putExtra(EXTRA_PORT, mac.port))
        }

        fun confirmPairing() {
            instance?.connection?.confirmPairing()
        }

        fun rejectPairing() {
            instance?.connection?.rejectPairing()
            LinkHub.update { it.copy(pairing = null) }
        }

        fun unlink(context: Context, id: String) {
            LinkedMacs(context).forget(id)
            instance?.let { service ->
                if (LinkHub.state.value.connectedId == id) service.connection?.close()
                service.publishLinked()
                service.updateBeacon()
            } ?: LinkHub.update { it.copy(linked = LinkedMacs(context).all()) }
        }

        /** Keep paired Macs linked, when there are any. */
        fun ensureRunning(context: Context) {
            val linked = LinkedMacs(context).all()
            LinkHub.update { it.copy(linked = linked) }
            if (linked.isNotEmpty() && instance == null) {
                context.startForegroundService(Intent(context, LinkService::class.java))
            }
        }

        /** The person turned hotspot requests on or off, or allowed Nearby devices. */
        fun refreshBeacon() {
            instance?.updateBeacon()
        }

        /** A Mac just said where it is: try it now rather than after the backoff. */
        fun poke(context: Context) {
            instance?.wakeUp()
        }
    }
}
