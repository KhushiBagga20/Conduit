package com.khushi.conduit.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.BatteryFull
import androidx.compose.material.icons.rounded.Coffee
import androidx.compose.material.icons.rounded.DeveloperMode
import androidx.compose.material.icons.rounded.NorthEast
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material.icons.rounded.WifiOff
import androidx.compose.material.icons.rounded.WifiTethering
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.system.Battery
import com.khushi.conduit.system.PhoneSetup
import com.khushi.conduit.system.SystemScreen
import com.khushi.conduit.system.WifiLink
import com.khushi.conduit.system.rememberBattery
import com.khushi.conduit.system.rememberPhoneIdentity
import com.khushi.conduit.system.rememberPhoneSettings
import com.khushi.conduit.system.rememberWifiLink
import com.khushi.conduit.ui.components.AvailabilityPill
import com.khushi.conduit.ui.components.BottomBarSpacer
import com.khushi.conduit.ui.components.CardDivider
import com.khushi.conduit.ui.components.CircleButton
import com.khushi.conduit.ui.components.ConduitMark
import com.khushi.conduit.ui.components.DotMatrixText
import com.khushi.conduit.ui.components.DottedMeter
import com.khushi.conduit.ui.components.GradientCard
import com.khushi.conduit.ui.components.HeroShape
import com.khushi.conduit.ui.components.IconBubble
import com.khushi.conduit.ui.components.NeedsPermissionDialog
import com.khushi.conduit.ui.components.Orbits
import com.khushi.conduit.ui.components.PageDots
import com.khushi.conduit.ui.components.PlainCard
import com.khushi.conduit.ui.components.SectionLabel
import com.khushi.conduit.ui.components.ToggleCard
import com.khushi.conduit.ui.components.detail
import com.khushi.conduit.ui.components.featuresAvailableToday
import com.khushi.conduit.ui.components.icon
import com.khushi.conduit.ui.components.title
import com.khushi.conduit.ui.theme.CardGradients
import com.khushi.conduit.ui.theme.LocalCanvas

/**
 * Home: this phone as Conduit for Mac sees it — whether it is ready, the
 * Wi-Fi link wireless mirroring runs over, the battery — and the phone-side
 * switches that exist today. Every number is live; every switch changes
 * something real; everything else says Planned.
 */
@Composable
fun HomeScreen() {
    val context = LocalContext.current
    val phone = rememberPhoneSettings()
    var askForPermission by remember { mutableStateOf(false) }

    HomeContent(
        phone = phone,
        wifi = rememberWifiLink(),
        battery = rememberBattery(),
        phoneName = rememberPhoneIdentity().name,
        onWirelessDebugging = { on -> if (!phone.setWirelessDebugging(on)) askForPermission = true },
        onStayAwake = { on -> if (!phone.setStayAwakeWhileCharging(on)) askForPermission = true },
        onOpen = { it.open(context) },
    )

    if (askForPermission) {
        NeedsPermissionDialog(
            onOpenDeveloperOptions = {
                askForPermission = false
                SystemScreen.DEVELOPER_OPTIONS.open(context)
            },
            onDismiss = { askForPermission = false },
        )
    }
}

@Composable
fun HomeContent(
    phone: PhoneSetup,
    wifi: WifiLink,
    battery: Battery?,
    phoneName: String,
    onWirelessDebugging: (Boolean) -> Unit,
    onStayAwake: (Boolean) -> Unit,
    onOpen: (SystemScreen) -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .statusBarsPadding(),
    ) {
        TopBar(phoneName = phoneName) { onOpen(SystemScreen.DEVELOPER_OPTIONS) }

        HeroPager(phone, wifi, battery, onOpen)

        Column(
            Modifier.padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SectionLabel("This phone")
            Row(
                Modifier.height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                SignalCard(wifi, Modifier.weight(1f).fillMaxHeight())
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    ToggleCard(
                        title = "Wireless debugging",
                        stateText = if (phone.wirelessDebugging) "On" else "Off",
                        icon = Icons.Rounded.WifiTethering,
                        checked = phone.wirelessDebugging,
                        colors = CardGradients.indigo,
                        locked = !phone.canChange,
                        onCheckedChange = onWirelessDebugging,
                    )
                    ToggleCard(
                        title = "Stay awake",
                        stateText = if (phone.stayAwakeWhileCharging) "While charging" else "Off",
                        icon = Icons.Rounded.Coffee,
                        checked = phone.stayAwakeWhileCharging,
                        colors = CardGradients.ember,
                        locked = !phone.canChange,
                        onCheckedChange = onStayAwake,
                    )
                }
            }
            if (!phone.canChange) {
                Text(
                    "To use these switches, click Allow in Conduit for Mac → Devices.",
                    color = LocalCanvas.current.contentSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(start = 4.dp),
                )
            }

            SectionLabel("With Conduit for Mac")
            PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
                val today = FeatureId.entries.filter { it in featuresAvailableToday }
                today.forEachIndexed { index, feature ->
                    if (index > 0) CardDivider()
                    FeatureRow(feature, Availability.AVAILABLE)
                }
                Text(
                    "Started from your Mac, over USB or Wi-Fi.",
                    color = LocalCanvas.current.contentSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 10.dp, start = 4.dp),
                )
            }

            SectionLabel("Coming to Conduit")
        }

        PlannedRow()
        BottomBarSpacer()
    }
}

@Composable
private fun TopBar(phoneName: String, onDeveloperOptions: () -> Unit) {
    val canvas = LocalCanvas.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ConduitMark(46.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                DesignTokens.Brand.NAME,
                color = canvas.content,
                style = MaterialTheme.typography.titleLarge.copy(fontSize = 24.sp, fontWeight = FontWeight.SemiBold),
            )
            Text(
                phoneName,
                color = canvas.contentSecondary,
                style = MaterialTheme.typography.bodySmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        CircleButton(Icons.Rounded.DeveloperMode, "Open Developer options", onClick = onDeveloperOptions)
    }
}

// Hero cards

private enum class HeroPage { READINESS, WIFI, BATTERY }

@Composable
private fun HeroPager(phone: PhoneSetup, wifi: WifiLink, battery: Battery?, onOpen: (SystemScreen) -> Unit) {
    val pages = HeroPage.entries
    val pagerState = rememberPagerState(pageCount = { pages.size })

    Column(Modifier.fillMaxWidth()) {
        HorizontalPager(
            state = pagerState,
            contentPadding = PaddingValues(horizontal = 20.dp),
            pageSpacing = 12.dp,
            modifier = Modifier.fillMaxWidth(),
        ) { index ->
            // Vertical room so each card's glow is not clipped by the pager.
            Box(Modifier.padding(vertical = 18.dp)) {
                when (pages[index]) {
                    HeroPage.READINESS -> ReadinessHero(phone) { onOpen(SystemScreen.DEVELOPER_OPTIONS) }
                    HeroPage.WIFI -> WifiHero(wifi) { onOpen(SystemScreen.WIFI) }
                    HeroPage.BATTERY -> BatteryHero(battery, phone) { onOpen(SystemScreen.BATTERY) }
                }
            }
        }
        PageDots(
            count = pages.size,
            current = pagerState.currentPage,
            color = LocalCanvas.current.content,
            modifier = Modifier.align(Alignment.CenterHorizontally),
        )
    }
}

@Composable
private fun ReadinessHero(phone: PhoneSetup, onOpen: () -> Unit) {
    val steps = listOf(phone.developerOptions, phone.usbDebugging, phone.wirelessDebugging)
    val (title, detail) = when {
        !phone.developerOptions -> "Set up this phone" to "Turn on Developer options, then USB debugging or Wireless debugging."
        phone.wirelessDebugging -> "Ready over Wi-Fi" to "Conduit for Mac can reach this phone on the same Wi-Fi network."
        phone.usbDebugging -> "Ready over USB" to "Turn on Wireless debugging to keep mirroring when you unplug."
        else -> "Almost ready" to "Turn on USB debugging or Wireless debugging in Developer options."
    }
    HeroCard(
        colors = CardGradients.magenta,
        label = "Ready for Mac",
        icon = Icons.Rounded.DeveloperMode,
        value = "${steps.count { it }}/${steps.size}",
        unit = "steps",
        title = title,
        detail = detail,
        actionLabel = "Open Developer options",
        onAction = onOpen,
    )
}

@Composable
private fun WifiHero(wifi: WifiLink, onOpen: () -> Unit) {
    HeroCard(
        colors = CardGradients.indigo,
        label = "Wi-Fi link",
        icon = if (wifi.connected) Icons.Rounded.Wifi else Icons.Rounded.WifiOff,
        value = when {
            !wifi.connected -> "OFF"
            else -> wifi.linkSpeedMbps?.toString() ?: "--"
        },
        unit = if (wifi.connected && wifi.linkSpeedMbps != null) "Mbps" else null,
        title = if (wifi.connected) wifi.quality else "Not on Wi-Fi",
        detail = if (wifi.connected) {
            "Wireless mirroring runs over this link."
        } else {
            "Join the same Wi-Fi as your Mac to mirror without a cable."
        },
        actionLabel = "Open Wi-Fi settings",
        onAction = onOpen,
    )
}

@Composable
private fun BatteryHero(battery: Battery?, phone: PhoneSetup, onOpen: () -> Unit) {
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
    HeroCard(
        colors = CardGradients.ember,
        label = "Battery",
        icon = if (battery?.charging == true) Icons.Rounded.BatteryChargingFull else Icons.Rounded.BatteryFull,
        value = battery?.let { "${it.percent}%" } ?: "--",
        unit = null,
        title = title,
        detail = detail,
        actionLabel = "Open battery settings",
        onAction = onOpen,
    )
}

@Composable
private fun HeroCard(
    colors: List<Color>,
    label: String,
    icon: ImageVector,
    value: String,
    unit: String?,
    title: String,
    detail: String,
    actionLabel: String,
    onAction: () -> Unit,
) {
    GradientCard(colors, Modifier.fillMaxWidth().heightIn(min = 318.dp), shape = HeroShape) {
        Orbits(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(64.dp),
        )
        Column(Modifier.padding(24.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.18f))
                        .padding(start = 10.dp, end = 14.dp, top = 7.dp, bottom = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(label, color = Color.White, style = MaterialTheme.typography.labelLarge)
                }
                Spacer(Modifier.weight(1f))
                CircleButton(Icons.Rounded.NorthEast, actionLabel, onGradient = true, onClick = onAction)
            }
            Spacer(Modifier.height(30.dp))
            Row(verticalAlignment = Alignment.Bottom) {
                DotMatrixText(value, dotPitch = 9.dp, color = Color.White)
                if (unit != null) {
                    Spacer(Modifier.width(10.dp))
                    Text(
                        unit,
                        color = Color.White.copy(alpha = 0.8f),
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(bottom = 2.dp),
                    )
                }
            }
            Spacer(Modifier.height(22.dp))
            Text(
                title,
                color = Color.White,
                style = MaterialTheme.typography.titleLarge.copy(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                detail,
                color = Color.White.copy(alpha = 0.78f),
                style = MaterialTheme.typography.bodyMedium,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(24.dp))
        }
    }
}

// This phone

@Composable
private fun SignalCard(wifi: WifiLink, modifier: Modifier = Modifier) {
    val canvas = LocalCanvas.current
    val hint = when {
        !wifi.connected -> "Wireless mirroring needs Wi-Fi."
        wifi.signalLevel == null -> "Signal strength is not available."
        wifi.signalLevel >= 3 -> "Good for wireless mirroring."
        wifi.signalLevel == 2 -> "Wireless mirroring may stutter."
        else -> "Move closer to the router, or use USB."
    }
    PlainCard(modifier, padding = 16.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconBubble(if (wifi.connected) Icons.Rounded.Wifi else Icons.Rounded.WifiOff)
            Spacer(Modifier.width(10.dp))
            Text("Signal", color = canvas.contentSecondary, style = MaterialTheme.typography.labelLarge)
        }
        Spacer(Modifier.weight(1f))
        Spacer(Modifier.height(18.dp))
        DotMatrixText(
            text = when {
                !wifi.connected -> "OFF"
                else -> wifi.rssiDbm?.toString() ?: "--"
            },
            dotPitch = 8.dp,
            color = canvas.content,
            hollow = false,
        )
        if (wifi.rssiDbm != null) {
            Text(
                "dBm",
                color = canvas.contentSecondary,
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.padding(top = 6.dp),
            )
        }
        Spacer(Modifier.height(16.dp))
        DottedMeter(
            fraction = wifi.signalFraction,
            modifier = Modifier.fillMaxWidth().height(14.dp),
            dots = 16,
            color = canvas.content,
            marker = canvas.lime,
        )
        Spacer(Modifier.height(14.dp))
        Text(
            if (wifi.connected) wifi.quality else "Not on Wi-Fi",
            color = canvas.content,
            style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
            maxLines = 2,
        )
        Text(hint, color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun FeatureRow(feature: FeatureId, availability: Availability) {
    val canvas = LocalCanvas.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconBubble(feature.icon())
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(feature.title(), color = canvas.content, style = MaterialTheme.typography.titleMedium)
            Text(feature.detail(), color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.width(8.dp))
        AvailabilityPill(availability)
    }
}

@Composable
private fun PlannedRow() {
    val canvas = LocalCanvas.current
    val planned = FeatureId.entries.filter { it !in featuresAvailableToday }
    Row(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 20.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        planned.forEach { feature ->
            PlainCard(Modifier.width(140.dp), padding = 16.dp) {
                IconBubble(feature.icon())
                Spacer(Modifier.height(14.dp))
                Text(
                    feature.title(),
                    color = canvas.content,
                    style = MaterialTheme.typography.titleMedium,
                    minLines = 2,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.height(10.dp))
                AvailabilityPill(Availability.PLANNED)
            }
        }
    }
}
