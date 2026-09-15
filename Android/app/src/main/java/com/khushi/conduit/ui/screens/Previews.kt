package com.khushi.conduit.ui.screens

import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview
import com.khushi.conduit.system.Battery
import com.khushi.conduit.system.PhoneSetupSample
import com.khushi.conduit.system.WifiLink
import com.khushi.conduit.ui.AppFrame
import com.khushi.conduit.ui.Destination
import com.khushi.conduit.ui.ThemeMode
import com.khushi.conduit.ui.theme.ConduitTheme

// Previews with sample data, for Android Studio.

@Composable
internal fun HomeSample(dark: Boolean, phone: PhoneSetupSample = PhoneSetupSample(), wifi: WifiLink = sampleWifi) {
    ConduitTheme(darkTheme = dark) {
        AppFrame(current = Destination.HOME, onSelect = {}) {
            HomeContent(
                phone = phone,
                wifi = wifi,
                battery = Battery(percent = 82, charging = true, source = "USB"),
                phoneName = "Galaxy S24 Ultra",
                onWirelessDebugging = {},
                onStayAwake = {},
                onOpen = {},
            )
        }
    }
}

internal val sampleWifi = WifiLink(connected = true, rssiDbm = -52, linkSpeedMbps = 866, signalLevel = 4)

@Preview(name = "Home — dark", uiMode = Configuration.UI_MODE_NIGHT_YES, widthDp = 384, heightDp = 832)
@Composable
private fun HomeDarkPreview() = HomeSample(dark = true)

@Preview(name = "Home — light", widthDp = 384, heightDp = 832)
@Composable
private fun HomeLightPreview() = HomeSample(dark = false)

@Preview(name = "Macs — dark", uiMode = Configuration.UI_MODE_NIGHT_YES, widthDp = 384, heightDp = 832)
@Composable
private fun MacsPreview() {
    ConduitTheme(darkTheme = true) {
        AppFrame(current = Destination.MACS, onSelect = {}) {
            MacsContent(phone = PhoneSetupSample(wirelessDebugging = false), onOpen = {})
        }
    }
}

@Preview(name = "Settings — dark", uiMode = Configuration.UI_MODE_NIGHT_YES, widthDp = 384, heightDp = 832)
@Composable
private fun SettingsPreview() {
    ConduitTheme(darkTheme = true) {
        AppFrame(current = Destination.SETTINGS, onSelect = {}) {
            SettingsContent(
                phone = PhoneSetupSample(canChange = false),
                themeMode = ThemeMode.SYSTEM,
                version = "0.1.0",
                onThemeMode = {},
                onWirelessDebugging = {},
                onStayAwake = {},
                onOpen = {},
            )
        }
    }
}
