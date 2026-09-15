package com.khushi.conduit.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Wifi
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.system.PhoneSettings
import com.khushi.conduit.system.PhoneSettingsState
import com.khushi.conduit.system.rememberPhoneSettings
import com.khushi.conduit.ui.components.ConduitCard
import com.khushi.conduit.ui.components.ConduitMark
import com.khushi.conduit.ui.components.NeedsPermissionDialog
import com.khushi.conduit.ui.components.SectionHeader
import com.khushi.conduit.ui.components.StatusDot
import com.khushi.conduit.ui.components.StatusTone
import com.khushi.conduit.ui.components.ToggleTile
import com.khushi.conduit.ui.components.icon
import com.khushi.conduit.ui.components.title
import com.khushi.conduit.ui.theme.LocalStatusColors

/**
 * Home: whether this phone is ready for Conduit for Mac, the phone-side
 * controls that exist today, and what is coming. Every tile that looks
 * switchable changes something real; the rest say Planned.
 */
@Composable
fun HomeScreen() {
    val context = LocalContext.current
    val phone = rememberPhoneSettings()
    var askForPermission by remember { mutableStateOf(false) }

    fun change(apply: () -> Boolean) {
        if (!apply()) askForPermission = true
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
    ) {
        Header()

        Column(
            Modifier.padding(horizontal = DesignTokens.Spacing.l.dp),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m.dp),
        ) {
            ReadinessCard(phone)

            SectionHeader("Controls")
            Row(horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m.dp)) {
                ToggleTile(
                    title = "Wireless debugging",
                    subtitle = if (phone.wirelessDebugging) "On" else "Off",
                    icon = Icons.Rounded.Wifi,
                    checked = phone.wirelessDebugging,
                    modifier = Modifier.weight(1f),
                ) { on -> change { phone.setWirelessDebugging(on) } }
                ToggleTile(
                    title = "Stay awake",
                    subtitle = if (phone.stayAwakeWhileCharging) "While charging" else "Off",
                    icon = Icons.Rounded.BatteryChargingFull,
                    checked = phone.stayAwakeWhileCharging,
                    modifier = Modifier.weight(1f),
                ) { on -> change { phone.setStayAwakeWhileCharging(on) } }
            }

            SectionHeader("Coming to Conduit")
            val planned = listOf(FeatureId.TRACKPAD, FeatureId.CAMERA, FeatureId.LINKS, FeatureId.FIND_MAC)
            planned.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m.dp)) {
                    row.forEach { feature ->
                        ToggleTile(
                            title = feature.title(),
                            subtitle = "Planned",
                            icon = feature.icon(),
                            checked = false,
                            enabled = false,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }

            SectionHeader("Works with Conduit for Mac", "Started from your Mac over USB or Wireless debugging.")
            ConduitCard {
                listOf(FeatureId.MIRRORING, FeatureId.REMOTE_INPUT, FeatureId.CLIPBOARD, FeatureId.AUDIO)
                    .forEach { feature ->
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .padding(vertical = DesignTokens.Spacing.s.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(feature.icon(), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            Spacer(Modifier.width(DesignTokens.Spacing.m.dp))
                            Text(feature.title(), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Icon(
                                Icons.Rounded.CheckCircle,
                                contentDescription = "Available",
                                tint = LocalStatusColors.current.connected,
                            )
                        }
                    }
            }
            Spacer(Modifier.height(DesignTokens.Spacing.l.dp))
        }
    }

    if (askForPermission) {
        NeedsPermissionDialog(
            onOpenDeveloperOptions = {
                askForPermission = false
                context.startActivity(PhoneSettings.developerOptionsIntent())
            },
            onDismiss = { askForPermission = false },
        )
    }
}

@Composable
private fun Header() {
    val scheme = MaterialTheme.colorScheme
    Column(
        Modifier
            .fillMaxWidth()
            .background(
                Brush.verticalGradient(listOf(scheme.primary.copy(alpha = 0.16f), scheme.background)),
            )
            .statusBarsPadding()
            .padding(
                start = DesignTokens.Spacing.l.dp,
                end = DesignTokens.Spacing.l.dp,
                top = DesignTokens.Spacing.xl.dp,
                bottom = DesignTokens.Spacing.l.dp,
            ),
    ) {
        ConduitMark(52.dp)
        Spacer(Modifier.height(DesignTokens.Spacing.m.dp))
        Text(DesignTokens.Brand.NAME, style = MaterialTheme.typography.displaySmall)
        Text(DesignTokens.Brand.TAGLINE, style = MaterialTheme.typography.bodyLarge, color = scheme.onSurfaceVariant)
    }
}

/** Whether Conduit for Mac can reach this phone, and the one next step if not. */
@Composable
private fun ReadinessCard(phone: PhoneSettingsState) {
    val (tone, title, detail) = when {
        !phone.developerOptions -> Triple(
            StatusTone.WORKING, "Set up this phone",
            "Turn on Developer options, then USB debugging or Wireless debugging.",
        )
        phone.wirelessDebugging -> Triple(
            StatusTone.CONNECTED, "Ready over Wi-Fi",
            "Conduit for Mac can reach this phone on the same Wi-Fi network.",
        )
        phone.usbDebugging -> Triple(
            StatusTone.CONNECTED, "Ready over USB",
            "Turn on Wireless debugging to keep mirroring when you unplug.",
        )
        else -> Triple(
            StatusTone.WORKING, "Almost ready",
            "Turn on USB debugging or Wireless debugging in Developer options.",
        )
    }

    ConduitCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(tone, 10.dp)
            Spacer(Modifier.width(DesignTokens.Spacing.s.dp))
            Text(title, style = MaterialTheme.typography.titleMedium)
        }
        Spacer(Modifier.height(DesignTokens.Spacing.xs.dp))
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (!phone.canChange) {
            Spacer(Modifier.height(DesignTokens.Spacing.s.dp))
            Text(
                "Pairing with Conduit for Mac is planned.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier
                    .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp))
                    .padding(horizontal = DesignTokens.Spacing.s.dp, vertical = DesignTokens.Spacing.xs.dp),
            )
        }
    }
}
