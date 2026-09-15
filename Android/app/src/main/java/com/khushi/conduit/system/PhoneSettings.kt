package com.khushi.conduit.system

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LifecycleResumeEffect

/**
 * The phone settings that decide whether Conduit for Mac can reach this
 * phone, read live and — once allowed — changed from the app.
 *
 * Changing Wireless debugging or "stay awake" needs WRITE_SECURE_SETTINGS,
 * which Android grants only over adb. Conduit for Mac grants it when the
 * phone is connected over USB and the user asks it to. Until then the
 * toggles explain that instead of silently failing.
 */
class PhoneSettings(context: Context) {

    private val appContext = context.applicationContext
    private val resolver get() = appContext.contentResolver

    val canChange: Boolean
        get() = appContext.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) ==
            PackageManager.PERMISSION_GRANTED

    val developerOptionsOn: Boolean get() = readGlobal(Settings.Global.DEVELOPMENT_SETTINGS_ENABLED) == 1
    val usbDebuggingOn: Boolean get() = readGlobal(Settings.Global.ADB_ENABLED) == 1
    val wirelessDebuggingOn: Boolean get() = readGlobal(ADB_WIFI_ENABLED) == 1
    val stayAwakeWhileChargingOn: Boolean get() = (readGlobal(Settings.Global.STAY_ON_WHILE_PLUGGED_IN) ?: 0) != 0

    fun setWirelessDebugging(on: Boolean): Boolean = writeGlobal(ADB_WIFI_ENABLED, if (on) 1 else 0)

    fun setStayAwakeWhileCharging(on: Boolean): Boolean =
        writeGlobal(Settings.Global.STAY_ON_WHILE_PLUGGED_IN, if (on) ALL_CHARGERS else 0)

    private fun readGlobal(key: String): Int? = try {
        Settings.Global.getInt(resolver, key, 0)
    } catch (_: SecurityException) {
        null
    }

    private fun writeGlobal(key: String, value: Int): Boolean = try {
        Settings.Global.putInt(resolver, key, value)
    } catch (_: SecurityException) {
        false
    }

    companion object {
        /** Settings.Global.ADB_WIFI_ENABLED, hidden from the public SDK. */
        const val ADB_WIFI_ENABLED = "adb_wifi_enabled"

        /** AC, USB and wireless chargers. */
        const val ALL_CHARGERS = 7

        val observedKeys = listOf(
            ADB_WIFI_ENABLED,
            Settings.Global.ADB_ENABLED,
            Settings.Global.STAY_ON_WHILE_PLUGGED_IN,
            Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
        )

        fun developerOptionsIntent(): Intent =
            Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}

/** Live, observable view of [PhoneSettings] for Compose. */
@Stable
class PhoneSettingsState internal constructor(private val settings: PhoneSettings) {
    var canChange by mutableStateOf(false)
        private set
    var developerOptions by mutableStateOf(false)
        private set
    var usbDebugging by mutableStateOf(false)
        private set
    var wirelessDebugging by mutableStateOf(false)
        private set
    var stayAwakeWhileCharging by mutableStateOf(false)
        private set

    init {
        refresh()
    }

    fun refresh() {
        canChange = settings.canChange
        developerOptions = settings.developerOptionsOn
        usbDebugging = settings.usbDebuggingOn
        wirelessDebugging = settings.wirelessDebuggingOn
        stayAwakeWhileCharging = settings.stayAwakeWhileChargingOn
    }

    /** Returns false when the app is not allowed to change it yet. */
    fun setWirelessDebugging(on: Boolean): Boolean = settings.setWirelessDebugging(on).also { refresh() }

    fun setStayAwakeWhileCharging(on: Boolean): Boolean = settings.setStayAwakeWhileCharging(on).also { refresh() }
}

@Composable
fun rememberPhoneSettings(): PhoneSettingsState {
    val context = LocalContext.current
    val state = remember { PhoneSettingsState(PhoneSettings(context)) }

    DisposableEffect(state) {
        val resolver = context.contentResolver
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) = state.refresh()
        }
        PhoneSettings.observedKeys.forEach {
            resolver.registerContentObserver(Settings.Global.getUriFor(it), false, observer)
        }
        onDispose { resolver.unregisterContentObserver(observer) }
    }

    // The permission can be granted from the Mac while the app is in the
    // background, so look again whenever the app comes back.
    LifecycleResumeEffect(state) {
        state.refresh()
        onPauseOrDispose { }
    }
    return state
}
