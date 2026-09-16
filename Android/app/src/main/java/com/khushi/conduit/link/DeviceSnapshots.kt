package com.khushi.conduit.link

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.BatteryStatus
import com.khushi.conduit.core.protocol.DeviceInfo
import com.khushi.conduit.core.protocol.DeviceSnapshot
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.core.protocol.NetworkStatus
import com.khushi.conduit.core.protocol.NetworkType
import com.khushi.conduit.core.protocol.Platform

/** What this phone tells a linked Mac about itself — spec §6 `Snapshot`. */
object DeviceSnapshots {

    fun device(context: Context, id: String): DeviceInfo {
        val name = runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }
            .getOrNull()?.takeIf { it.isNotBlank() } ?: Build.MODEL
        val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull()
        return DeviceInfo(
            id = id,
            name = name,
            model = Build.MODEL,
            manufacturer = Build.MANUFACTURER,
            platform = Platform.ANDROID,
            osVersion = Build.VERSION.RELEASE,
            appVersion = version,
        )
    }

    fun snapshot(context: Context, id: String) = DeviceSnapshot(
        device = device(context, id),
        battery = battery(context),
        network = NetworkStatus(network(context)),
        features = mapOf(
            // Everything today goes through adb; the rest arrives over the link.
            FeatureId.MIRRORING.wire to Availability.AVAILABLE,
            FeatureId.REMOTE_INPUT.wire to Availability.AVAILABLE,
            FeatureId.CLIPBOARD.wire to Availability.AVAILABLE,
            FeatureId.AUDIO.wire to Availability.AVAILABLE,
        ),
    )

    private fun battery(context: Context): BatteryStatus? {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return null
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        return BatteryStatus(
            level = level * 100 / scale,
            charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL,
        )
    }

    private fun network(context: Context): NetworkType {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return NetworkType.NONE
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkType.WIFI
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkType.CELLULAR
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> NetworkType.ETHERNET
            else -> NetworkType.NONE
        }
    }
}
