package com.khushi.conduit.ui.screens

import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.DeveloperMode
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import com.khushi.conduit.ui.components.ConduitMark
import com.khushi.conduit.ui.components.QuickActionTile
import com.khushi.conduit.ui.components.SectionHeader
import com.khushi.conduit.ui.components.StatusDot
import com.khushi.conduit.ui.components.StatusTone
import com.khushi.conduit.ui.components.icon
import com.khushi.conduit.ui.components.title

/**
 * Home: connection status, what works today, and the quick actions Conduit
 * will offer. Until pairing lands, the actions are labelled Planned rather
 * than pretending to work.
 */
@Composable
fun HomeScreen() {
    val context = LocalContext.current

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = DesignTokens.Spacing.l.dp, vertical = DesignTokens.Spacing.l.dp),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.l.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ConduitMark(36.dp)
            Spacer(Modifier.width(DesignTokens.Spacing.m.dp))
            Column {
                Text(DesignTokens.Brand.NAME, style = MaterialTheme.typography.headlineSmall)
                Text(DesignTokens.Brand.TAGLINE, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }

        ConduitCard {
            Row(verticalAlignment = Alignment.CenterVertically) {
                StatusDot(StatusTone.IDLE, 10.dp)
                Spacer(Modifier.width(DesignTokens.Spacing.s.dp))
                Text("Not paired with a Mac", style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f))
                AvailabilityChip(Availability.PLANNED)
            }
            Spacer(Modifier.height(DesignTokens.Spacing.s.dp))
            Text(
                "Pairing with Conduit for Mac — for links, calls and using this phone as a trackpad — " +
                    "arrives in the next update.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        SectionHeader("Works today", "From Conduit for Mac, over USB or Wireless debugging.")
        ConduitCard {
            listOf(FeatureId.MIRRORING, FeatureId.REMOTE_INPUT, FeatureId.CLIPBOARD, FeatureId.AUDIO).forEach { feature ->
                Row(Modifier.fillMaxWidth().padding(vertical = DesignTokens.Spacing.xs.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(feature.icon(), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                    Spacer(Modifier.width(DesignTokens.Spacing.m.dp))
                    Text(feature.title(), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                }
            }
            Spacer(Modifier.height(DesignTokens.Spacing.m.dp))
            OutlinedButton(onClick = {
                context.startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }) {
                Icon(Icons.Rounded.DeveloperMode, contentDescription = null)
                Spacer(Modifier.width(DesignTokens.Spacing.s.dp))
                Text("Open Developer options")
            }
        }

        SectionHeader("Quick actions")
        val actions = listOf(
            Triple(DesignTokens.Term.mirrorScreen, FeatureId.MIRRORING.icon(), Availability.PLANNED),
            Triple(DesignTokens.Term.useAsTrackpad, FeatureId.TRACKPAD.icon(), Availability.PLANNED),
            Triple(DesignTokens.Term.useCamera, FeatureId.CAMERA.icon(), Availability.PLANNED),
            Triple(DesignTokens.Term.shareLink, FeatureId.LINKS.icon(), Availability.PLANNED),
            Triple(DesignTokens.Term.findMac, FeatureId.FIND_MAC.icon(), Availability.PLANNED),
            Triple(DesignTokens.Term.disconnect, Icons.Rounded.LinkOff, Availability.PLANNED),
        )
        actions.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m.dp)) {
                row.forEach { (title, icon, availability) ->
                    QuickActionTile(title, icon, availability, Modifier.weight(1f))
                }
            }
        }
    }
}
