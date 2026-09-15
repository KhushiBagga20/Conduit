package com.khushi.conduit.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.ui.components.AvailabilityChip
import com.khushi.conduit.ui.components.ConduitCard
import com.khushi.conduit.ui.components.EmptyState
import com.khushi.conduit.ui.components.SectionHeader
import com.khushi.conduit.ui.components.icon
import com.khushi.conduit.ui.components.title

@Composable
private fun ScreenColumn(title: String, content: @Composable () -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(DesignTokens.Spacing.l.dp),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.l.dp),
    ) {
        Text(title, style = MaterialTheme.typography.headlineSmall)
        content()
    }
}

/** Paired Macs. Empty until pairing exists — and it says so. */
@Composable
fun MacsScreen() {
    ScreenColumn("Macs") {
        EmptyState(
            icon = Icons.Rounded.LaptopMac,
            title = "No Macs yet",
            message = "Pair a Mac running Conduit to share links, take calls and use this phone as its trackpad.",
        ) {
            AvailabilityChip(Availability.PLANNED)
        }
    }
}

/** Every Conduit feature and whether it works today. */
@Composable
fun FeaturesScreen() {
    val today = setOf(FeatureId.MIRRORING, FeatureId.REMOTE_INPUT, FeatureId.CLIPBOARD, FeatureId.AUDIO)

    ScreenColumn("Features") {
        SectionHeader("Works today", "Started from Conduit for Mac over USB or Wireless debugging.")
        FeatureList(FeatureId.entries.filter { it in today }, Availability.AVAILABLE)

        SectionHeader("Coming to Conduit")
        FeatureList(FeatureId.entries.filter { it !in today }, Availability.PLANNED)
    }
}

@Composable
private fun FeatureList(features: List<FeatureId>, availability: Availability) {
    ConduitCard {
        features.forEachIndexed { index, feature ->
            if (index > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outline)
            Row(Modifier.fillMaxWidth().padding(vertical = DesignTokens.Spacing.m.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Icon(feature.icon(), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(DesignTokens.Spacing.m.dp))
                Text(feature.title(), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                AvailabilityChip(availability)
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
            message = "Connections, shared links, calls and clipboard syncs will appear here once this phone is paired with a Mac.",
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
    val version = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull() ?: "—"

    ScreenColumn("Settings") {
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
            Text("Version $version", style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
