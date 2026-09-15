package com.khushi.conduit.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.DeveloperMode
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.system.PhoneSettings
import com.khushi.conduit.system.rememberPhoneSettings
import com.khushi.conduit.ui.LocalAppPreferences
import com.khushi.conduit.ui.ThemeMode
import com.khushi.conduit.ui.components.AvailabilityChip
import com.khushi.conduit.ui.components.ConduitCard
import com.khushi.conduit.ui.components.EmptyState
import com.khushi.conduit.ui.components.NeedsPermissionDialog
import com.khushi.conduit.ui.components.SectionHeader
import com.khushi.conduit.ui.components.SwitchRow
import com.khushi.conduit.ui.components.icon
import com.khushi.conduit.ui.components.title
import com.khushi.conduit.ui.theme.LocalStatusColors

@Composable
private fun ScreenColumn(title: String, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .statusBarsPadding()
            .padding(DesignTokens.Spacing.l.dp),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m.dp),
    ) {
        Text(
            title,
            style = MaterialTheme.typography.headlineSmall,
            modifier = Modifier.padding(top = DesignTokens.Spacing.s.dp, bottom = DesignTokens.Spacing.xs.dp),
        )
        content()
    }
}

/** How to connect this phone to a Mac today, with live status for each step. */
@Composable
fun MacsScreen() {
    val context = LocalContext.current
    val phone = rememberPhoneSettings()

    ScreenColumn("Macs") {
        EmptyState(
            icon = Icons.Rounded.LaptopMac,
            title = "No paired Macs",
            message = "Pairing a Mac — for links, calls and using this phone as a trackpad — is planned. " +
                "Conduit for Mac already mirrors this phone over USB or Wi-Fi.",
        ) { AvailabilityChip(Availability.PLANNED) }

        SectionHeader("Connect to Conduit for Mac")
        ConduitCard {
            SetupStep("Developer options", "Settings → About phone → Software information → tap Build number 7 times.", phone.developerOptions)
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            SetupStep("USB debugging", "For a cable connection.", phone.usbDebugging)
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            SetupStep("Wireless debugging", "For Wi-Fi. Conduit for Mac finds this phone by itself.", phone.wirelessDebugging)
            FilledTonalButton(
                onClick = { context.startActivity(PhoneSettings.developerOptionsIntent()) },
                modifier = Modifier.padding(top = DesignTokens.Spacing.m.dp),
            ) {
                Icon(Icons.Rounded.DeveloperMode, contentDescription = null)
                Spacer(Modifier.width(DesignTokens.Spacing.s.dp))
                Text("Open Developer options")
            }
        }
    }
}

@Composable
private fun SetupStep(title: String, detail: String, done: Boolean) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = { Text(detail) },
        leadingContent = {
            Icon(
                if (done) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
                contentDescription = if (done) "On" else "Off",
                tint = if (done) LocalStatusColors.current.connected else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    )
}

private enum class FeatureFilter(val label: String) { ALL("All"), AVAILABLE("Available"), PLANNED("Planned") }

/** Every Conduit feature and whether it works today, filterable. */
@Composable
fun FeaturesScreen() {
    val today = setOf(FeatureId.MIRRORING, FeatureId.REMOTE_INPUT, FeatureId.CLIPBOARD, FeatureId.AUDIO)
    var filter by rememberSaveable { mutableStateOf(FeatureFilter.ALL) }

    ScreenColumn("Features") {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            FeatureFilter.entries.forEachIndexed { index, option ->
                SegmentedButton(
                    selected = filter == option,
                    onClick = { filter = option },
                    shape = SegmentedButtonDefaults.itemShape(index, FeatureFilter.entries.size),
                ) { Text(option.label) }
            }
        }

        val shown = FeatureId.entries.filter { feature ->
            when (filter) {
                FeatureFilter.ALL -> true
                FeatureFilter.AVAILABLE -> feature in today
                FeatureFilter.PLANNED -> feature !in today
            }
        }
        ConduitCard {
            shown.forEachIndexed { index, feature ->
                if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outline)
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = DesignTokens.Spacing.m.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(feature.icon(), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(DesignTokens.Spacing.m.dp))
                    Text(feature.title(), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    AvailabilityChip(if (feature in today) Availability.AVAILABLE else Availability.PLANNED)
                }
            }
        }
    }
}

@Composable
fun ActivityScreen() {
    ScreenColumn("Activity") {
        EmptyState(
            icon = Icons.Rounded.History,
            title = "No activity yet",
            message = "Shared links, calls and clipboard syncs will appear here once this phone is paired with a Mac.",
        )
    }
}

/**
 * Settings that exist today. Toggles for features that are not built are not
 * shown: a switch that does nothing is worse than no switch.
 */
@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val preferences = LocalAppPreferences.current
    val phone = rememberPhoneSettings()
    var askForPermission by remember { mutableStateOf(false) }
    val version = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull() ?: "—"

    ScreenColumn("Settings") {
        SectionHeader("Appearance")
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            ThemeMode.entries.forEachIndexed { index, mode ->
                SegmentedButton(
                    selected = preferences.themeMode == mode,
                    onClick = { preferences.updateThemeMode(mode) },
                    shape = SegmentedButtonDefaults.itemShape(index, ThemeMode.entries.size),
                ) { Text(mode.label) }
            }
        }

        SectionHeader("Connection")
        ConduitCard {
            SwitchRow(
                title = "Wireless debugging",
                supporting = "Lets Conduit for Mac reach this phone over Wi-Fi.",
                icon = Icons.Rounded.Wifi,
                checked = phone.wirelessDebugging,
            ) { on -> if (!phone.setWirelessDebugging(on)) askForPermission = true }
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            SwitchRow(
                title = "Stay awake while charging",
                supporting = "Keeps the screen on while plugged in, so mirroring never sleeps.",
                icon = Icons.Rounded.BatteryChargingFull,
                checked = phone.stayAwakeWhileCharging,
            ) { on -> if (!phone.setStayAwakeWhileCharging(on)) askForPermission = true }
            HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            ListItem(
                headlineContent = { Text("Developer options") },
                supportingContent = { Text(if (phone.canChange) "Conduit can change these for you." else "Change these settings yourself.") },
                leadingContent = { Icon(Icons.Rounded.DeveloperMode, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                modifier = Modifier.padding(0.dp),
            )
            FilledTonalButton(onClick = { context.startActivity(PhoneSettings.developerOptionsIntent()) }) {
                Text("Open Developer options")
            }
        }

        SectionHeader("Privacy")
        ConduitCard {
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Rounded.Lock, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(DesignTokens.Spacing.m.dp))
                Text(
                    "Conduit asks for each permission only when you use the feature that needs it. " +
                        "Nothing from this app is included in backups or device transfers.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        SectionHeader("About Conduit")
        ConduitCard {
            Text(DesignTokens.Brand.TAGLINE, style = MaterialTheme.typography.titleMedium)
            Text("Version $version", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
