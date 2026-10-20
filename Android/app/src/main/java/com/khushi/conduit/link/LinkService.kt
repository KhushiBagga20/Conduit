package com.khushi.conduit.link

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.PersistableBundle
import android.os.Looper
import android.os.VibrationEffect
import android.os.VibratorManager
import android.util.Log
import android.widget.Toast
import com.khushi.conduit.MainActivity
import com.khushi.conduit.R
import com.khushi.conduit.core.link.HotspotRequestGate
import com.khushi.conduit.core.link.LinkSharing
import com.khushi.conduit.core.protocol.ActionName
import com.khushi.conduit.core.protocol.DeviceInfo
import com.khushi.conduit.core.protocol.DeviceSnapshot
import com.khushi.conduit.core.protocol.Envelope
import com.khushi.conduit.core.protocol.EnvelopeKind
import com.khushi.conduit.core.protocol.ErrorCode
import com.khushi.conduit.core.protocol.EventName
import com.khushi.conduit.core.protocol.HandshakeIntent
import com.khushi.conduit.core.protocol.InputEvent
import com.khushi.conduit.core.protocol.LinkSessionInfo
import com.khushi.conduit.core.protocol.Outcome
import com.khushi.conduit.core.protocol.PhoneNotification
import com.khushi.conduit.core.protocol.ProtocolError
import com.khushi.conduit.core.protocol.Vibration
import com.khushi.conduit.notifications.NotificationRelay
import com.khushi.conduit.system.SystemScreen
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

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
    @Volatile private var statusText = "Looking for your Mac"

    private val main = Handler(Looper.getMainLooper())
    /**
     * Something the person asked to send while no Mac was linked yet — a
     * link or the clipboard. In memory only, and only briefly.
     */
    private val queued = AtomicReference<((LinkConnection, String) -> Unit)?>(null)
    /** Commands sent to the Mac and not answered yet, by request ID. */
    private val awaiting = ConcurrentHashMap<String, (Outcome?) -> Unit>()
    private val linkNotifications = AtomicInteger(0)

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
        notifications.createNotificationChannel(
            NotificationChannel(LINKS_CHANNEL, "Links from your Mac", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Links your Mac sends to this phone. Tap one to open it."
            },
        )
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, notification(statusText),
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
            ACTION_SEND_LINK -> intent.getStringExtra(EXTRA_URL)?.let { url ->
                sendWhenLinked { link, mac -> sendLink(link, url, mac) }
            }
            ACTION_SEND_CLIPBOARD -> intent.getStringExtra(EXTRA_TEXT)?.let { text ->
                val sensitive = intent.getBooleanExtra(EXTRA_SENSITIVE, false)
                sendWhenLinked { link, mac -> sendClipboard(link, text, sensitive, mac) }
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
        main.removeCallbacksAndMessages(null)
        queued.set(null)
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
                    queued.getAndSet(null)?.let { send ->
                        main.removeCallbacks(giveUpOnQueued)
                        send(connection, mac.name)
                    }
                }

                override fun onEnvelope(connection: LinkConnection, envelope: Envelope) = handle(connection, envelope)

                override fun onVibrate(vibration: Vibration) = buzz(vibration)

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
                ActionName.LINK_SEND -> linkFromMac(connection, kind.requestId, envelope)
                ActionName.CLIPBOARD_SET -> clipboardFromMac(connection, kind.requestId, envelope)
                ActionName.NOTIFICATION_SYNC -> connection.send(
                    if (NotificationRelay.isListening(this)) {
                        Envelope(
                            EnvelopeKind.Response(kind.requestId, Outcome.Success),
                            buildJsonObject {
                                put("notifications", Json.encodeToJsonElement(
                                    ListSerializer(PhoneNotification.serializer()), NotificationRelay.showing()))
                            },
                        )
                    } else {
                        Envelope(EnvelopeKind.Response(kind.requestId, Outcome.Failure(ProtocolError(
                            ErrorCode.REQUIRES_SETUP,
                            "Conduit isn't allowed to see this phone's notifications. On the phone: Conduit → " +
                                "Settings → Notifications → Allow notification access.",
                        ))))
                    },
                )
                ActionName.NOTIFICATION_DISMISS -> notificationAction(connection, kind.requestId, envelope, open = false)
                    .also { Log.i(TAG, "the Mac dismissed a notification") }
                ActionName.NOTIFICATION_OPEN -> notificationAction(connection, kind.requestId, envelope, open = true)
                else -> connection.send(Envelope(EnvelopeKind.Response(kind.requestId, Outcome.Failure(
                    ProtocolError(ErrorCode.UNSUPPORTED, "This version of Conduit for Android does not do that yet."),
                ))))
            }
            is EnvelopeKind.Response -> awaiting.remove(kind.requestId)?.invoke(kind.outcome)
            is EnvelopeKind.Event -> Unit
        }
    }

    /**
     * Send a command and hand its answer to [answered]; null means it went
     * unanswered for the 15 seconds the spec allows.
     */
    private fun ask(connection: LinkConnection, action: String, payload: JsonObject?, answered: (Outcome?) -> Unit) {
        val requestId = UUID.randomUUID().toString()
        awaiting[requestId] = answered
        connection.send(Envelope(EnvelopeKind.Command(requestId, action), payload))
        main.postDelayed({ awaiting.remove(requestId)?.invoke(null) }, ANSWER_MILLIS)
    }

    // Notifications

    /**
     * The Mac dismissed a notification, or asked the phone to open what it
     * points at. Android may still refuse to bring an app forward from the
     * background, so success here means the phone tried.
     */
    private fun notificationAction(connection: LinkConnection, requestId: String, envelope: Envelope, open: Boolean) {
        val key = (envelope.payload?.get("key") as? JsonPrimitive)?.takeIf { it.isString }?.content
        val outcome = when {
            key == null -> Outcome.Failure(ProtocolError(ErrorCode.INVALID_REQUEST, "That needs a notification key."))
            !NotificationRelay.isListening(this) -> Outcome.Failure(ProtocolError(ErrorCode.REQUIRES_SETUP,
                "Conduit isn't allowed to see notifications on the phone."))
            open && !NotificationRelay.open(key) -> Outcome.Failure(ProtocolError(ErrorCode.DEVICE_UNAVAILABLE,
                "The phone couldn't open that notification."))
            !open && !NotificationRelay.dismiss(key) -> Outcome.Failure(ProtocolError(ErrorCode.DEVICE_UNAVAILABLE,
                "That notification is already gone."))
            else -> Outcome.Success
        }
        connection.send(Envelope(EnvelopeKind.Response(requestId, outcome)))
    }

    private fun event(name: String, payload: JsonObject) {
        val connection = connection ?: return
        connection.send(Envelope(
            EnvelopeKind.Event(name, epoch, seq.incrementAndGet(), System.currentTimeMillis()), payload))
    }

    // The trackpad

    /**
     * Tell the Mac the trackpad screen is open. [answered] gets null when the
     * Mac will take it, or the reason it will not — the phone shows that
     * instead of moving nothing.
     */
    private fun startTrackpad(answered: (ProtocolError?) -> Unit) {
        val connection = connection
        if (connection == null || connectedMacName() == null) {
            main.post { answered(ProtocolError(ErrorCode.DEVICE_UNAVAILABLE, "Conduit isn't linked to your Mac right now.")) }
            return
        }
        ask(connection, ActionName.TRACKPAD_START, null) { outcome ->
            val error = when (outcome) {
                null -> ProtocolError(ErrorCode.TIMEOUT, "Your Mac didn't answer.")
                Outcome.Success -> null
                is Outcome.Failure -> outcome.error
            }
            main.post { answered(error) }
        }
    }

    private fun stopTrackpad() {
        val connection = connection ?: return
        ask(connection, ActionName.TRACKPAD_STOP, null) {}
    }

    /** A click landing on the Mac, felt here — Shared/Protocol §7, `haptic`. */
    private fun buzz(vibration: Vibration) {
        val vibrator = getSystemService(VibratorManager::class.java)?.defaultVibrator ?: return
        if (!vibrator.hasVibrator()) return
        runCatching {
            vibrator.vibrate(VibrationEffect.createOneShot(
                vibration.durationMs.toLong().coerceIn(1, 100), vibration.amplitude))
        }
    }

    // Find my Mac

    /** Ask the linked Mac to make a sound, for finding it. */
    private fun ringMac() {
        val connection = connection
        val mac = connectedMacName()
        if (connection == null || mac == null) {
            toast("Not linked to your Mac right now.")
            return
        }
        Log.i(TAG, "asked the Mac to ring")
        ask(connection, ActionName.MAC_FIND, null) { outcome ->
            when (outcome) {
                null -> toast("$mac didn't answer.")
                Outcome.Success -> toast("$mac is ringing. Stop it there when you find it.")
                is Outcome.Failure -> toast("$mac can't ring. ${outcome.error.message}")
            }
        }
    }

    // Links

    /**
     * The Mac sent a link. Android does not let a service open an app by
     * itself, so the link waits in a notification; only its site is shown.
     */
    private fun linkFromMac(connection: LinkConnection, requestId: String, envelope: Envelope) {
        val url = (envelope.payload?.get("url") as? JsonPrimitive)?.takeIf { it.isString }?.content
            ?.let(LinkSharing::acceptableUrl)
        val outcome = when {
            url == null -> Outcome.Failure(ProtocolError(ErrorCode.INVALID_REQUEST, "Only web links can be opened."))
            !canNotify(LINKS_CHANNEL) -> Outcome.Failure(ProtocolError(ErrorCode.PERMISSION_DENIED,
                "Notifications from Conduit are off on the phone, so the link can't be shown."))
            else -> {
                showLink(url, connectedMacName() ?: "your Mac")
                Outcome.Success
            }
        }
        Log.i(TAG, if (outcome is Outcome.Failure) "turned down a link from the Mac: ${outcome.error.code}" else "showed a link from the Mac")
        connection.send(Envelope(EnvelopeKind.Response(requestId, outcome)))
    }

    private fun showLink(url: String, macName: String) {
        // A few at a time, so a second link does not replace the first.
        val id = LINK_NOTIFICATION_BASE + linkNotifications.getAndIncrement() % 20
        val view = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val open = PendingIntent.getActivity(this, id, view, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        getSystemService(NotificationManager::class.java).notify(id,
            Notification.Builder(this, LINKS_CHANNEL)
                .setSmallIcon(R.drawable.ic_link)
                .setContentTitle("Link from $macName")
                .setContentText("${LinkSharing.siteName(url)} · Tap to open")
                .setContentIntent(open)
                .setAutoCancel(true)
                .build())
    }

    /** Send now if the Mac is linked; otherwise wait a little for the link to come up. */
    private fun sendWhenLinked(send: (LinkConnection, String) -> Unit) {
        val link = connection
        val mac = connectedMacName()
        if (link != null && mac != null) {
            send(link, mac)
            return
        }
        queued.set(send)
        main.removeCallbacks(giveUpOnQueued)
        main.postDelayed(giveUpOnQueued, LINK_WAIT_MILLIS)
        toast("Waiting for your Mac…")
        wakeUp()
    }

    private val giveUpOnQueued = Runnable {
        if (queued.getAndSet(null) != null) toast("Couldn't reach your Mac, so nothing was sent.")
    }

    // Clipboard

    /**
     * The Mac copied something. Writing the clipboard from the background is
     * allowed — only reading it is not. Nothing is kept or logged.
     */
    private fun clipboardFromMac(connection: LinkConnection, requestId: String, envelope: Envelope) {
        val text = (envelope.payload?.get("text") as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (text.isNullOrEmpty() || text.length > MAX_CLIPBOARD_CHARS) {
            connection.send(Envelope(EnvelopeKind.Response(requestId, Outcome.Failure(
                ProtocolError(ErrorCode.INVALID_REQUEST, "That clipboard was empty or too large.")))))
            return
        }
        val sensitive = (envelope.payload?.get("sensitive") as? JsonPrimitive)?.booleanOrNull == true
        main.post {
            val clip = ClipData.newPlainText("From your Mac", text)
            if (sensitive && Build.VERSION.SDK_INT >= 33) {
                clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
            }
            runCatching { getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip) }
        }
        Log.i(TAG, "put the Mac's clipboard on this phone")
        connection.send(Envelope(EnvelopeKind.Response(requestId, Outcome.Success)))
    }

    private fun sendClipboard(connection: LinkConnection, text: String, sensitive: Boolean, macName: String) {
        Log.i(TAG, "sent this phone's clipboard to the Mac")
        ask(connection, ActionName.CLIPBOARD_SET, buildJsonObject {
            put("text", text)
            put("sensitive", sensitive)
        }) { outcome ->
            when (outcome) {
                null -> toast("$macName didn't answer.")
                Outcome.Success -> toast("Copied to $macName")
                is Outcome.Failure -> toast("$macName didn't take it. ${outcome.error.message}")
            }
        }
    }

    private fun sendLink(connection: LinkConnection, url: String, macName: String) {
        Log.i(TAG, "sent a link to the Mac")
        ask(connection, ActionName.LINK_SEND, buildJsonObject { put("url", url) }) { outcome ->
            when (outcome) {
                null -> toast("$macName didn't answer, so the link may not have opened.")
                Outcome.Success -> {
                    Log.i(TAG, "the Mac opened the link")
                    toast("Opened on $macName")
                }
                is Outcome.Failure -> {
                    Log.i(TAG, "the Mac turned down the link: ${outcome.error.code}")
                    toast("$macName didn't open the link. ${outcome.error.message}")
                }
            }
        }
    }

    private fun connectedMacName(): String? {
        val state = LinkHub.state.value
        return state.connectedId?.let { id -> state.linked.firstOrNull { it.id == id }?.name }
    }

    private fun canNotify(channel: String): Boolean {
        val notifications = getSystemService(NotificationManager::class.java)
        return notifications.areNotificationsEnabled() &&
            notifications.getNotificationChannel(channel)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun toast(text: String) {
        main.post { Toast.makeText(applicationContext, text, Toast.LENGTH_SHORT).show() }
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

    private fun notify(text: String) {
        statusText = text
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(text))
    }

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
        private const val LINKS_CHANNEL = "links"
        private const val LINK_NOTIFICATION_BASE = 100
        private const val LINK_WAIT_MILLIS = 20_000L
        /** The spec gives a command 15 seconds to be answered. */
        private const val ANSWER_MILLIS = 15_000L
        private const val ACTION_PAIR = "com.khushi.conduit.link.PAIR"
        private const val ACTION_STOP = "com.khushi.conduit.link.STOP"
        private const val ACTION_SEND_LINK = "com.khushi.conduit.link.SEND_LINK"
        private const val ACTION_SEND_CLIPBOARD = "com.khushi.conduit.link.SEND_CLIPBOARD"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_SENSITIVE = "sensitive"
        /** The Mac's limit is 256 KiB; characters are at least one byte each. */
        private const val MAX_CLIPBOARD_CHARS = 256 * 1024
        private const val EXTRA_ID = "id"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_HOSTS = "hosts"
        private const val EXTRA_PORT = "port"
        private const val EXTRA_URL = "url"

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

        /** The trackpad screen opened: [answered] gets null, or why the Mac will not take it. */
        fun startTrackpad(answered: (ProtocolError?) -> Unit) {
            instance?.startTrackpad(answered)
                ?: answered(ProtocolError(ErrorCode.DEVICE_UNAVAILABLE, "Conduit isn't linked to your Mac right now."))
        }

        /** The trackpad screen closed. */
        fun stopTrackpad() {
            instance?.stopTrackpad()
        }

        /**
         * Trackpad input for the linked Mac. Dropped when no Mac is linked:
         * the trackpad screen shows that, and a queue of stale movement would
         * arrive as a jump later.
         */
        fun input(event: InputEvent) {
            instance?.connection?.send(event)
        }

        /** A notification arrived on the phone and may go to the Mac. */
        fun notificationPosted(notification: PhoneNotification) {
            val service = instance ?: return
            if (service.connection == null) return
            // What happened, never what it said.
            Log.i(TAG, "sent a notification to the Mac")
            service.event(EventName.NOTIFICATION_POSTED,
                Json.encodeToJsonElement(PhoneNotification.serializer(), notification).jsonObject)
        }

        /** It is gone from the phone, however it went. */
        fun notificationRemoved(key: String) {
            instance?.event(EventName.NOTIFICATION_REMOVED, buildJsonObject { put("key", key) })
        }

        /** Notification access came or went: the Mac's feature list should say so. */
        fun refreshFeatures() {
            val service = instance ?: return
            service.connection?.let(service::sendSnapshot)
        }

        /** Ring the linked Mac, for finding it. */
        fun ring(context: Context) {
            instance?.ringMac()
                ?: Toast.makeText(context, "Not linked to your Mac right now.", Toast.LENGTH_SHORT).show()
        }

        /** Put text on the linked Mac's clipboard, starting the link first if it is not running. */
        fun sendClipboard(context: Context, text: String, sensitive: Boolean) {
            context.startForegroundService(Intent(context, LinkService::class.java)
                .setAction(ACTION_SEND_CLIPBOARD).putExtra(EXTRA_TEXT, text).putExtra(EXTRA_SENSITIVE, sensitive))
        }

        /** Send a web link to the linked Mac, which opens it, starting the link first if it is not running. */
        fun sendLink(context: Context, url: String) {
            context.startForegroundService(Intent(context, LinkService::class.java)
                .setAction(ACTION_SEND_LINK).putExtra(EXTRA_URL, url))
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
