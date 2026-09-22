package com.khushi.conduit.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Coffee
import androidx.compose.material.icons.rounded.DeveloperMode
import androidx.compose.material.icons.rounded.PrivacyTip
import androidx.compose.material.icons.rounded.WifiTethering
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.link.HotspotBeacon
import com.khushi.conduit.link.HotspotRequests
import com.khushi.conduit.link.LinkHub
import com.khushi.conduit.link.LinkService
import com.khushi.conduit.system.PhoneSetup
import com.khushi.conduit.system.SystemScreen
import com.khushi.conduit.system.rememberHotspotAddress
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
import com.khushi.conduit.ui.theme.LocalStatusColors

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
    val link by LinkHub.state.collectAsState()

    // Android 13+ hides the "Linked to" notification without this; linking
    // still works if the person says no.
    val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        LinkService.startAdding(context)
    }

    fun nearbyGranted() = HotspotBeacon.NEEDED.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }
    var hotspotRequests by remember { mutableStateOf(HotspotRequests.enabled(context) && nearbyGranted()) }
    val nearby = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        val granted = results.values.all { it }
        HotspotRequests.setEnabled(context, granted)
        hotspotRequests = granted
    }

    MacsContent(
        phone = rememberPhoneSettings(),
        hotspotAddress = rememberHotspotAddress(),
        link = link,
        actions = MacsActions(
            addMac = {
                if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                    LinkService.startAdding(context)
                } else {
                    notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            },
            stopAdding = { LinkService.stopAdding(context) },
            pair = { LinkService.pair(context, it) },
            confirmPairing = LinkService::confirmPairing,
            rejectPairing = LinkService::rejectPairing,
            unlink = { LinkService.unlink(context, it) },
            setHotspotRequests = { on ->
                if (on && !nearbyGranted()) {
                    nearby.launch(HotspotBeacon.NEEDED)
                } else {
                    HotspotRequests.setEnabled(context, on)
                    hotspotRequests = on
                }
            },
        ),
        hotspotRequests = hotspotRequests,
        onOpen = { it.open(context) },
    )
}

/** What the Macs screen can ask Conduit Link to do. */
class MacsActions(
    val addMac: () -> Unit = {},
    val stopAdding: () -> Unit = {},
    val pair: (LinkHub.FoundMac) -> Unit = {},
    val confirmPairing: () -> Unit = {},
    val rejectPairing: () -> Unit = {},
    val unlink: (String) -> Unit = {},
    val setHotspotRequests: (Boolean) -> Unit = {},
)

@Composable
fun MacsContent(
    phone: PhoneSetup,
    hotspotAddress: String?,
    link: LinkHub.State,
    actions: MacsActions,
    onOpen: (SystemScreen) -> Unit,
    hotspotRequests: Boolean = false,
) {
    ScreenColumn("Macs") {
        LinkedMacsSection(link, actions, hotspotRequests)

        SectionLabel("Mirroring from Conduit for Mac")
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

        SectionLabel("Away from Wi-Fi")
        HotspotCard(hotspotAddress, onOpen)
    }
}

/**
 * Conduit Link: the Macs this phone is paired with, adding one, and the six
 * digits both people compare before either device trusts the other.
 */
@Composable
private fun LinkedMacsSection(link: LinkHub.State, actions: MacsActions, hotspotRequests: Boolean) {
    val canvas = LocalCanvas.current

    if (link.linked.isEmpty() && !link.adding) {
        DottedEmptyState(
            title = "No Macs linked yet",
            message = "Link a Mac to share links, files and notifications with it. It works on any network " +
                "you share — including this phone's hotspot — and needs no developer options.",
        ) {
            PillButton("Add Mac", icon = Icons.Rounded.Add, onClick = actions.addMac)
        }
    }

    if (link.linked.isNotEmpty()) {
        SectionLabel("Linked Macs")
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            link.linked.forEachIndexed { index, mac ->
                if (index > 0) CardDivider()
                val connected = link.connectedId == mac.id
                Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconBubble(Icons.Rounded.LaptopMac)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(mac.name, color = canvas.content, style = MaterialTheme.typography.titleMedium)
                        Text(
                            if (connected) "Linked now" else "Last seen ${DateUtils.getRelativeTimeSpanString(mac.lastSeen)}",
                            color = if (connected) LocalStatusColors.current.connected else canvas.contentSecondary,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    TextButton(onClick = { actions.unlink(mac.id) }) { Text("Unlink", color = canvas.contentSecondary) }
                }
            }
        }
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            SwitchRow(
                icon = Icons.Rounded.WifiTethering,
                title = "Let your Mac ask for the hotspot",
                supporting = when {
                    !hotspotRequests -> "When your Mac is offline it can ask over Bluetooth, and you get a notification to turn the hotspot on."
                    link.hotspotRequestsReady -> "Listening over Bluetooth. Only your linked Mac can ask."
                    else -> "Starts listening once Bluetooth is on. Only your linked Mac can ask."
                },
                checked = hotspotRequests,
                onCheckedChange = actions.setHotspotRequests,
            )
        }
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            Row(Modifier.fillMaxWidth().padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconBubble(Icons.Rounded.Link)
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text("Send links", color = canvas.content, style = MaterialTheme.typography.titleMedium)
                    Text(
                        "In any app, tap Share, then Send to Mac, and the link opens on your Mac. Links your Mac " +
                            "sends arrive here as a notification.",
                        color = canvas.contentSecondary,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
        if (!link.adding) {
            PillButton("Add another Mac", icon = Icons.Rounded.Add, modifier = Modifier.fillMaxWidth(), onClick = actions.addMac)
        }
    }

    if (link.adding) {
        SectionLabel("Add a Mac")
        PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
            Text(
                "On the Mac, open Conduit → Devices → Add Phone. Macs appear here when they are on a network this " +
                    "phone can reach, or when your Mac is connected to this phone over adb.",
                color = canvas.contentSecondary,
                style = MaterialTheme.typography.bodySmall,
            )
            Spacer(Modifier.height(8.dp))
            if (link.found.isEmpty()) {
                Row(Modifier.padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = canvas.content, strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Looking for Macs…", color = canvas.content, style = MaterialTheme.typography.bodyMedium)
                }
            }
            link.found.forEachIndexed { index, found ->
                if (index > 0) CardDivider()
                Row(
                    Modifier.fillMaxWidth().clickable { actions.pair(found) }.padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconBubble(Icons.Rounded.LaptopMac)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Text(found.name, color = canvas.content, style = MaterialTheme.typography.titleMedium)
                        Text(found.hosts.first(), color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
                    }
                    Text("Pair", color = canvas.content, style = MaterialTheme.typography.labelLarge)
                }
            }
            (link.status as? LinkHub.Status.Failed)?.let {
                Text(it.message, color = LocalStatusColors.current.error, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 8.dp))
            }
            (link.status as? LinkHub.Status.Connecting)?.let {
                Text("Contacting ${it.macName}…", color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 8.dp))
            }
        }
        TextButton(onClick = actions.stopAdding, modifier = Modifier.fillMaxWidth()) {
            Text("Cancel", color = canvas.contentSecondary)
        }
    }

    link.pairing?.let { prompt ->
        AlertDialog(
            onDismissRequest = actions.rejectPairing,
            icon = { Icon(Icons.Rounded.LaptopMac, contentDescription = null) },
            title = { Text("Pair with ${prompt.macName}") },
            text = {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                    Text("Check that your Mac shows these digits too.")
                    Spacer(Modifier.height(16.dp))
                    Text(
                        prompt.code.chunked(3).joinToString(" "),
                        style = MaterialTheme.typography.displaySmall.copy(fontFamily = FontFamily.Monospace),
                    )
                }
            },
            confirmButton = { TextButton(onClick = actions.confirmPairing) { Text("Pair") } },
            dismissButton = { TextButton(onClick = actions.rejectPairing) { Text("Don't pair") } },
        )
    }
}

/**
 * Using the phone's own hotspot, for when there is no Wi-Fi network to
 * share. Android turns Wireless debugging off whenever Wi-Fi is off, so
 * Conduit for Mac opens adb's own port instead — from the Mac, while the
 * phone is still connected.
 */
@Composable
private fun HotspotCard(hotspotAddress: String?, onOpen: (SystemScreen) -> Unit) {
    val canvas = LocalCanvas.current
    PlainCard(Modifier.fillMaxWidth(), padding = 16.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconBubble(Icons.Rounded.WifiTethering)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text("Use this phone's hotspot", color = canvas.content, style = MaterialTheme.typography.titleMedium)
                Text(
                    if (hotspotAddress != null) "Hotspot on at $hotspotAddress" else "Hotspot off",
                    color = if (hotspotAddress != null) LocalStatusColors.current.connected else canvas.contentSecondary,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        Spacer(Modifier.height(12.dp))
        HotspotStep(1, "On the Mac, while this phone is connected, open Conduit → Devices → Get Ready.")
        HotspotStep(2, "Turn this phone's hotspot on.")
        HotspotStep(3, "Join the Mac to the hotspot. Conduit finds the phone by itself.")
        Spacer(Modifier.height(12.dp))
        PillButton("Open hotspot settings", modifier = Modifier.fillMaxWidth()) { onOpen(SystemScreen.HOTSPOT) }
    }
}

@Composable
private fun HotspotStep(number: Int, text: String) {
    val canvas = LocalCanvas.current
    Row(Modifier.padding(vertical = 4.dp)) {
        Text(
            "$number",
            color = canvas.contentSecondary,
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.width(20.dp),
        )
        Text(text, color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
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
                Column {
                    Text(
                        "Conduit asks for each permission only when you use the feature that needs it. " +
                            "Nothing from this app is included in backups or device transfers.",
                        color = canvas.contentSecondary,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "While Conduit for Mac mirrors this phone with its screen off, it turns on Conduit touch " +
                            "guard: an accessibility service that ignores touches on the phone and reads nothing " +
                            "on the screen. Pressing the power button turns it off.",
                        color = canvas.contentSecondary,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
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
