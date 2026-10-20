package com.khushi.conduit.ui.screens

import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.DeveloperMode
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khushi.conduit.TrackpadActivity
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.link.LinkHub
import com.khushi.conduit.link.LinkService
import com.khushi.conduit.system.Battery
import com.khushi.conduit.system.PhoneSetup
import com.khushi.conduit.system.SystemScreen
import com.khushi.conduit.system.WifiLink
import com.khushi.conduit.system.rememberBattery
import com.khushi.conduit.system.rememberPhoneIdentity
import com.khushi.conduit.system.rememberPhoneSettings
import com.khushi.conduit.system.rememberWifiLink
import com.khushi.conduit.ui.components.BottomSpacer
import com.khushi.conduit.ui.components.Chevron
import com.khushi.conduit.ui.components.ConduitMark
import com.khushi.conduit.ui.components.FlatBox
import com.khushi.conduit.ui.components.ItemRow
import com.khushi.conduit.ui.components.Line
import com.khushi.conduit.ui.components.SectionLabel
import com.khushi.conduit.ui.components.StatusDot
import com.khushi.conduit.ui.components.StatusTone
import com.khushi.conduit.ui.components.TrailingText
import com.khushi.conduit.ui.theme.LocalCanvas
import com.khushi.conduit.ui.theme.LocalStatusColors

/**
 * Home: where this phone stands with your Mac, and the state of the phone
 * itself — set up for mirroring, its Wi-Fi link, its battery. Every number is
 * live, and each row opens the setting it describes.
 */
@Composable
fun HomeScreen() {
    val context = LocalContext.current
    val link by LinkHub.state.collectAsState()

    HomeContent(
        phone = rememberPhoneSettings(),
        wifi = rememberWifiLink(),
        battery = rememberBattery(),
        phoneName = rememberPhoneIdentity().name,
        link = link,
        onOpen = { it.open(context) },
        onTrackpad = { context.startActivity(Intent(context, TrackpadActivity::class.java)) },
        onRing = { LinkService.ring(context) },
    )
}

@Composable
fun HomeContent(
    phone: PhoneSetup,
    wifi: WifiLink,
    battery: Battery?,
    phoneName: String,
    link: LinkHub.State,
    onOpen: (SystemScreen) -> Unit,
    onTrackpad: () -> Unit,
    onRing: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .statusBarsPadding()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Header(phoneName)

        SectionLabel("Your Mac")
        FlatBox {
            MacRow(link)
            Line()
            ItemRow("Use as trackpad", icon = Icons.Rounded.TouchApp, onClick = onTrackpad) { Chevron() }
            Line()
            ItemRow("Ring your Mac", icon = Icons.Rounded.NotificationsActive, onClick = onRing) { Chevron() }
        }

        SectionLabel("This phone")
        FlatBox {
            ReadinessRow(phone) { onOpen(SystemScreen.DEVELOPER_OPTIONS) }
            Line()
            WifiRow(wifi) { onOpen(SystemScreen.WIFI) }
            Line()
            BatteryRow(battery, phone) { onOpen(SystemScreen.BATTERY) }
        }

        BottomSpacer()
    }
}

@Composable
private fun Header(phoneName: String) {
    val canvas = LocalCanvas.current
    Row(Modifier.padding(start = 4.dp, top = 20.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        ConduitMark(40.dp)
        Spacer(Modifier.width(14.dp))
        Column {
            Text(
                DesignTokens.Brand.NAME,
                color = canvas.content,
                style = MaterialTheme.typography.headlineSmall.copy(fontSize = 26.sp, fontWeight = FontWeight.SemiBold),
            )
            Text(
                phoneName,
                color = canvas.contentSecondary,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** The linked Mac, and whether it is reachable right now. */
@Composable
private fun MacRow(link: LinkHub.State) {
    val connected = link.linked.firstOrNull { it.id == link.connectedId }
    val (title, detail, tone) = when {
        connected != null -> Triple(connected.name, "Linked now", StatusTone.CONNECTED)
        link.linked.isNotEmpty() -> Triple(link.linked.first().name, "Not reachable right now", StatusTone.IDLE)
        else -> Triple("No Mac linked", "Add one in Macs", StatusTone.IDLE)
    }
    ItemRow(
        title,
        supporting = detail,
        supportingColor = if (tone == StatusTone.CONNECTED) LocalStatusColors.current.connected else null,
        icon = Icons.Rounded.LaptopMac,
    ) { StatusDot(tone) }
}

@Composable
private fun ReadinessRow(phone: PhoneSetup, onOpen: () -> Unit) {
    val steps = listOf(phone.developerOptions, phone.usbDebugging, phone.wirelessDebugging)
    val (title, detail) = when {
        !phone.developerOptions -> "Set up for mirroring" to "Turn on Developer options, then USB or Wireless debugging."
        phone.wirelessDebugging -> "Ready over Wi-Fi" to "Your Mac can reach this phone on the same Wi-Fi."
        phone.usbDebugging -> "Ready over USB" to "Turn on Wireless debugging to keep mirroring when you unplug."
        else -> "Almost ready" to "Turn on USB debugging or Wireless debugging."
    }
    ItemRow(title, supporting = detail, icon = Icons.Rounded.DeveloperMode, onClick = onOpen) {
        TrailingText("${steps.count { it }}/${steps.size}")
    }
}

@Composable
private fun WifiRow(wifi: WifiLink, onOpen: () -> Unit) {
    val detail = when {
        !wifi.connected -> "Join your Mac's Wi-Fi to mirror without a cable."
        wifi.signalLevel == null -> "Wireless mirroring runs over this link."
        wifi.signalLevel >= 3 -> "Good for wireless mirroring."
        wifi.signalLevel == 2 -> "Wireless mirroring may stutter."
        else -> "Move closer to the router, or use USB."
    }
    ItemRow(
        if (wifi.connected) "Wi-Fi · ${wifi.quality}" else "Not on Wi-Fi",
        supporting = listOfNotNull(wifi.rssiDbm?.takeIf { wifi.connected }?.let { "$it dBm" }, detail).joinToString(" · "),
        icon = if (wifi.connected) Icons.Rounded.Wifi else Icons.Rounded.WifiOff,
        onClick = onOpen,
    ) {
        wifi.linkSpeedMbps?.takeIf { wifi.connected }?.let { TrailingText("$it Mbps") }
    }
}

@Composable
private fun BatteryRow(battery: Battery?, phone: PhoneSetup, onOpen: () -> Unit) {
    val title = when {
        battery == null -> "Battery"
        !battery.charging -> "On battery"
        battery.source == "USB" -> "Charging over USB"
        battery.source == "wireless charger" -> "Charging wirelessly"
        else -> "Charging"
    }
    val detail = when {
        battery == null -> "Battery level is not available."
        battery.charging && phone.stayAwakeWhileCharging -> "Stay awake is on, so the screen stays on while charging."
        battery.charging -> "Stay awake is off."
        else -> "Mirroring uses more battery than usual."
    }
    ItemRow(
        title,
        supporting = detail,
        icon = if (battery?.charging == true) Icons.Rounded.BatteryChargingFull else Icons.Rounded.BatteryFull,
        onClick = onOpen,
    ) {
        TrailingText(battery?.let { "${it.percent}%" } ?: "—")
    }
}
