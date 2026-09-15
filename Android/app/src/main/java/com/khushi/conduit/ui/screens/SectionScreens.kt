package com.khushi.conduit.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Coffee
import androidx.compose.material.icons.rounded.DeveloperMode
import androidx.compose.material.icons.rounded.PrivacyTip
import androidx.compose.material.icons.rounded.WifiTethering
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.system.PhoneSetup
import com.khushi.conduit.system.SystemScreen
import com.khushi.conduit.system.rememberPhoneSettings
import com.khushi.conduit.ui.LocalAppPreferences
import com.khushi.conduit.ui.ThemeMode
import com.khushi.conduit.ui.components.AvailabilityPill
import com.khushi.conduit.ui.components.BottomBarSpacer
import com.khushi.conduit.ui.components.CardDivider
import com.khushi.conduit.ui.components.ConduitMark
import com.khushi.conduit.ui.components.DottedEmptyState
import com.khushi.conduit.ui.components.IconBubble
import com.khushi.conduit.ui.components.NeedsPermissionDialog
import com.khushi.conduit.ui.components.PillButton
import com.khushi.conduit.ui.components.PillSegments
import com.khushi.conduit.ui.components.PlainCard
import com.khushi.conduit.ui.components.ScreenTitle
import com.khushi.conduit.ui.components.SectionLabel
import com.khushi.conduit.ui.components.SwitchRow
import com.khushi.conduit.ui.components.detail
import com.khushi.conduit.ui.components.featuresAvailableToday
import com.khushi.conduit.ui.components.icon
import com.khushi.conduit.ui.components.title
import com.khushi.conduit.ui.theme.LocalCanvas

@Composable
private fun ScreenColumn(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .statusBarsPadding()
            .padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ScreenTitle(title, Modifier.padding(top = 20.dp, start = 4.dp, bottom = 4.dp))
        content()
        BottomBarSpacer()
    }
}

/** How to connect this phone to a Mac today, with live status for each step. */
@Composable
fun MacsScreen() {
    val context = LocalContext.current
    MacsContent(phone = rememberPhoneSettings(), onOpen = { it.open(context) })
}

@Composable
fun MacsContent(phone: PhoneSetup, onOpen: (SystemScreen) -> Unit) {
    ScreenColumn("Macs") {
        DottedEmptyState(
            title = "No paired Macs",
            message = "Pairing a Mac — for links, calls and using this phone as a trackpad — is planned. " +
                "Conduit for Mac already mirrors this phone over USB or Wi-Fi.",
        ) { AvailabilityPill(Availability.PLANNED) }

        SectionLabel("Connect to Conduit for Mac")
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            SetupStep(1, "Developer options", "Settings → About phone → Software information → tap Build number 7 times.", phone.developerOptions)
            CardDivider()
            SetupStep(2, "USB debugging", "For a cable connection, and to let your Mac in the first time.", phone.usbDebugging)
            CardDivider()
            SetupStep(3, "Wireless debugging", "For Wi-Fi. Conduit for Mac finds this phone by itself.", phone.wirelessDebugging)
        }
        PillButton(
            "Open Developer options",
            icon = Icons.Rounded.DeveloperMode,
            modifier = Modifier.fillMaxWidth(),
        ) { onOpen(SystemScreen.DEVELOPER_OPTIONS) }
    }
}

@Composable
private fun SetupStep(number: Int, title: String, detail: String, done: Boolean) {
    val canvas = LocalCanvas.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 12.dp)
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(36.dp)
                .then(
                    if (done) {
                        Modifier.background(canvas.lime, CircleShape)
                    } else {
                        Modifier.border(1.5.dp, canvas.content.copy(alpha = 0.25f), CircleShape)
                    },
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (done) {
                Icon(Icons.Rounded.Check, contentDescription = null, tint = canvas.background, modifier = Modifier.size(20.dp))
            } else {
                Text("$number", color = canvas.contentSecondary, style = MaterialTheme.typography.labelLarge)
            }
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = canvas.content, style = MaterialTheme.typography.titleMedium)
            Text(detail, color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.width(10.dp))
        Text(
            if (done) "On" else "Off",
            color = if (done) canvas.content else canvas.contentSecondary,
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.semantics { contentDescription = if (done) "On" else "Off" },
        )
    }
}

private enum class FeatureFilter(val label: String) { ALL("All"), AVAILABLE("Available"), PLANNED("Planned") }

/** Every Conduit feature and whether it works today, filterable. */
@Composable
fun FeaturesScreen() {
    val canvas = LocalCanvas.current
    var filter by rememberSaveable { mutableStateOf(FeatureFilter.ALL) }

    ScreenColumn("Features") {
        PillSegments(FeatureFilter.entries, filter, label = { it.label }) { filter = it }

        val shown = FeatureId.entries.filter { feature ->
            when (filter) {
                FeatureFilter.ALL -> true
                FeatureFilter.AVAILABLE -> feature in featuresAvailableToday
                FeatureFilter.PLANNED -> feature !in featuresAvailableToday
            }
        }
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            shown.forEachIndexed { index, feature ->
                if (index > 0) CardDivider()
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconBubble(feature.icon())
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(feature.title(), color = canvas.content, style = MaterialTheme.typography.titleMedium)
                        Text(feature.detail(), color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
                    }
                    Spacer(Modifier.width(8.dp))
                    AvailabilityPill(if (feature in featuresAvailableToday) Availability.AVAILABLE else Availability.PLANNED)
                }
            }
        }
        Text(
            "Available features are started from Conduit for Mac while this phone is connected.",
            color = canvas.contentSecondary,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(horizontal = 4.dp),
        )
    }
}

@Composable
fun ActivityScreen() {
    ScreenColumn("Activity") {
        Spacer(Modifier.height(24.dp))
        DottedEmptyState(
            title = "No activity yet",
            message = "Shared links, calls and clipboard syncs will appear here once this phone is paired with a Mac.",
        ) { AvailabilityPill(Availability.PLANNED) }
    }
}

/**
 * Settings that exist today. Switches for features that are not built are
 * not shown: a switch that does nothing is worse than no switch.
 */
@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val preferences = LocalAppPreferences.current
    val phone = rememberPhoneSettings()
    var askForPermission by remember { mutableStateOf(false) }
    val version = remember {
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "—"
    }

    SettingsContent(
        phone = phone,
        themeMode = preferences.themeMode,
        version = version,
        onThemeMode = preferences::updateThemeMode,
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
fun SettingsContent(
    phone: PhoneSetup,
    themeMode: ThemeMode,
    version: String,
    onThemeMode: (ThemeMode) -> Unit,
    onWirelessDebugging: (Boolean) -> Unit,
    onStayAwake: (Boolean) -> Unit,
    onOpen: (SystemScreen) -> Unit,
) {
    val canvas = LocalCanvas.current

    ScreenColumn("Settings") {
        SectionLabel("Appearance")
        PillSegments(ThemeMode.entries, themeMode, label = { it.label }, onSelect = onThemeMode)

        SectionLabel("Connection")
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            SwitchRow(
                icon = Icons.Rounded.WifiTethering,
                title = "Wireless debugging",
                supporting = "Lets Conduit for Mac reach this phone over Wi-Fi.",
                checked = phone.wirelessDebugging,
                onCheckedChange = onWirelessDebugging,
            )
            CardDivider()
            SwitchRow(
                icon = Icons.Rounded.Coffee,
                title = "Stay awake while charging",
                supporting = "Keeps the screen on while plugged in.",
                checked = phone.stayAwakeWhileCharging,
                onCheckedChange = onStayAwake,
            )
            CardDivider()
            Row(Modifier.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconBubble(Icons.Rounded.DeveloperMode)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text("Developer options", color = canvas.content, style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (phone.canChange) {
                            "Conduit can change the switches above for you."
                        } else {
                            "To use the switches above, click Allow in Conduit for Mac → Devices."
                        },
                        color = canvas.contentSecondary,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
            PillButton("Open Developer options", modifier = Modifier.fillMaxWidth()) {
                onOpen(SystemScreen.DEVELOPER_OPTIONS)
            }
        }

        SectionLabel("Privacy")
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            Row(verticalAlignment = Alignment.Top) {
                IconBubble(Icons.Rounded.PrivacyTip)
                Spacer(Modifier.width(14.dp))
                Text(
                    "Conduit asks for each permission only when you use the feature that needs it. " +
                        "Nothing from this app is included in backups or device transfers.",
                    color = canvas.contentSecondary,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }

        SectionLabel("About")
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ConduitMark(44.dp)
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(
                        DesignTokens.Brand.NAME,
                        color = canvas.content,
                        style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                    )
                    Text("Version $version", color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
                }
            }
            Spacer(Modifier.height(12.dp))
            Text(DesignTokens.Brand.TAGLINE, color = canvas.contentSecondary, style = MaterialTheme.typography.bodyMedium)
        }
    }
}
