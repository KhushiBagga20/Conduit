package com.khushi.conduit.system

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay

/**
 * Live facts about this phone that matter to Conduit: battery, and the
 * quality of the Wi-Fi link that wireless mirroring runs over.
 *
 * Needs no runtime permission (ACCESS_NETWORK_STATE is granted at install).
 * The Wi-Fi network's name is deliberately not read — Android ties it to
 * location access, and signal strength and link speed are what describe
 * mirroring quality anyway.
 */
@Immutable
data class Battery(val percent: Int, val charging: Boolean, val source: String?)

@Immutable
data class WifiLink(
    val connected: Boolean,
    val rssiDbm: Int? = null,
    val linkSpeedMbps: Int? = null,
    /** 0…4. */
    val signalLevel: Int? = null,
) {
    /** Signal strength from -90 dBm (0) to -30 dBm (1), for meters. */
    val signalFraction: Float
        get() = rssiDbm?.let { ((it + 90) / 60f).coerceIn(0f, 1f) } ?: 0f

    val quality: String
        get() = when (signalLevel) {
            null -> if (connected) "Connected" else "Not on Wi-Fi"
            4 -> "Excellent signal"
            3 -> "Good signal"
            2 -> "Fair signal"
            else -> "Weak signal"
        }
}

@Immutable
data class PhoneIdentity(val name: String, val model: String, val androidVersion: String)

@Composable
fun rememberBattery(): Battery? {
    val context = LocalContext.current
    var battery by remember { mutableStateOf<Battery?>(null) }

    DisposableEffect(Unit) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                battery = intent.toBattery()
            }
        }
        // ACTION_BATTERY_CHANGED is sticky: registering returns the current value.
        context.registerReceiver(receiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let {
            battery = it.toBattery()
        }
        onDispose { context.unregisterReceiver(receiver) }
    }
    return battery
}

private fun Intent.toBattery(): Battery? {
    val level = getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
    val scale = getIntExtra(BatteryManager.EXTRA_SCALE, -1)
    if (level < 0 || scale <= 0) return null
    val status = getIntExtra(BatteryManager.EXTRA_STATUS, -1)
    val plugged = getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
    val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
    val source = when (plugged) {
        BatteryManager.BATTERY_PLUGGED_USB -> "USB"
        BatteryManager.BATTERY_PLUGGED_AC -> "charger"
        BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless charger"
        else -> null
    }
    return Battery(percent = level * 100 / scale, charging = charging, source = source)
}

/**
 * The Wi-Fi link, followed whether or not it is the phone's default network:
 * wireless mirroring only needs the local network, not the internet.
 */
@Composable
fun rememberWifiLink(): WifiLink {
    val context = LocalContext.current
    val monitor = remember { WifiLinkMonitor(context) }

    DisposableEffect(monitor) {
        monitor.start()
        onDispose { monitor.stop() }
    }

    // Signal strength drifts without a capabilities change, so look again
    // every few seconds while the app is on screen.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(monitor, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                monitor.poll()
                delay(4_000)
            }
        }
    }
    return monitor.link
}

private class WifiLinkMonitor(context: Context) {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val wifi = context.getSystemService(WifiManager::class.java)
    private var network: Network? = null

    var link by mutableStateOf(WifiLink(connected = false))
        private set

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            this@WifiLinkMonitor.network = network
            link = read(capabilities)
        }

        override fun onLost(network: Network) {
            if (network == this@WifiLinkMonitor.network) {
                this@WifiLinkMonitor.network = null
                link = WifiLink(connected = false)
            }
        }
    }

    fun start() {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.registerNetworkCallback(request, callback, Handler(Looper.getMainLooper()))
    }

    fun stop() {
        connectivity.unregisterNetworkCallback(callback)
        network = null
    }

    fun poll() {
        val current = network ?: return
        connectivity.getNetworkCapabilities(current)?.let { link = read(it) }
    }

    private fun read(capabilities: NetworkCapabilities): WifiLink {
        val info = capabilities.transportInfo as? WifiInfo
        val rssi = info?.rssi?.takeIf { it > -127 && it < 0 }
        return WifiLink(
            connected = true,
            rssiDbm = rssi,
            linkSpeedMbps = info?.linkSpeed?.takeIf { it > 0 },
            signalLevel = rssi?.let { r ->
                val max = wifi.maxSignalLevel.coerceAtLeast(1)
                (wifi.calculateSignalLevel(r) * 4 / max).coerceIn(0, 4)
            },
        )
    }
}

@Composable
fun rememberPhoneIdentity(): PhoneIdentity {
    val context = LocalContext.current
    return remember {
        val name = runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }
            .getOrNull()?.takeIf { it.isNotBlank() } ?: Build.MODEL
        PhoneIdentity(name = name, model = Build.MODEL, androidVersion = Build.VERSION.RELEASE)
    }
}
