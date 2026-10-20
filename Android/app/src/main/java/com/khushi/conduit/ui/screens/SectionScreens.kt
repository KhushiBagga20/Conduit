package com.khushi.conduit.ui.screens

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.text.format.DateUtils
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Coffee
import androidx.compose.material.icons.rounded.DeveloperMode
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.WifiTethering
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.unit.dp
import com.khushi.conduit.TrackpadActivity
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.link.HotspotBeacon
import com.khushi.conduit.link.HotspotRequests
import com.khushi.conduit.link.LinkHub
import com.khushi.conduit.link.LinkService
import com.khushi.conduit.notifications.NotificationApps
import com.khushi.conduit.notifications.NotificationRelay
import com.khushi.conduit.system.PhoneSetup
import com.khushi.conduit.system.SystemScreen
import com.khushi.conduit.system.rememberHotspotAddress
import com.khushi.conduit.system.rememberPhoneSettings
import com.khushi.conduit.ui.LocalAppPreferences
import com.khushi.conduit.ui.ThemeMode
import com.khushi.conduit.ui.components.AvailabilityTag
import com.khushi.conduit.ui.components.BottomSpacer
import com.khushi.conduit.ui.components.Chevron
import com.khushi.conduit.ui.components.ConduitMark
import com.khushi.conduit.ui.components.EmptyState
import com.khushi.conduit.ui.components.FlatBox
import com.khushi.conduit.ui.components.FlatButton
import com.khushi.conduit.ui.components.Footnote
import com.khushi.conduit.ui.components.ItemRow
import com.khushi.conduit.ui.components.Line
import com.khushi.conduit.ui.components.NeedsPermissionDialog
import com.khushi.conduit.ui.components.RowAction
import com.khushi.conduit.ui.components.ScreenTitle
import com.khushi.conduit.ui.components.SectionLabel
import com.khushi.conduit.ui.components.Segmented
import com.khushi.conduit.ui.components.SwitchRow
import com.khushi.conduit.ui.components.TrailingText
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
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        ScreenTitle(title, Modifier.padding(top = 20.dp, start = 4.dp, bottom = 4.dp))
        content()
        BottomSpacer()
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
            ring = { LinkService.ring(context) },
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
    val ring: () -> Unit = {},
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

        SectionLabel("Mirroring")
        FlatBox {
            SetupStep(1, "Developer options", "Settings → About phone → Software information → tap Build number 7 times.", phone.developerOptions)
            Line()
            SetupStep(2, "USB debugging", "For a cable connection, and to let your Mac in the first time.", phone.usbDebugging)
            Line()
            SetupStep(3, "Wireless debugging", "For Wi-Fi. Conduit for Mac finds this phone by itself.", phone.wirelessDebugging)
            Line()
            ItemRow("Open Developer options", icon = Icons.Rounded.DeveloperMode, onClick = { onOpen(SystemScreen.DEVELOPER_OPTIONS) }) {
                Chevron()
            }
        }

        SectionLabel("Away from Wi-Fi")
        HotspotBox(hotspotAddress, onOpen)
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
        EmptyState(
            title = "No Mac linked yet",
            message = "Link a Mac to share links, files and notifications with it. It works on any network " +
                "you share — including this phone's hotspot — and needs no developer options.",
        ) {
            FlatButton("Add Mac", icon = Icons.Rounded.Add, onClick = actions.addMac)
        }
    }

    if (link.linked.isNotEmpty()) {
        SectionLabel("Linked")
        FlatBox {
            link.linked.forEachIndexed { index, mac ->
                if (index > 0) Line()
                val connected = link.connectedId == mac.id
                ItemRow(
                    mac.name,
                    supporting = if (connected) "Linked now" else "Last seen ${DateUtils.getRelativeTimeSpanString(mac.lastSeen)}",
                    supportingColor = if (connected) LocalStatusColors.current.connected else null,
                    icon = Icons.Rounded.LaptopMac,
                ) {
                    if (connected) RowAction("Ring", onClick = actions.ring)
                    RowAction("Unlink", secondary = true) { actions.unlink(mac.id) }
                }
            }
            Line()
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
        Footnote(
            "Share → Send to Mac opens a link on your Mac, or puts other text on its clipboard. What you copy " +
                "on your Mac lands here by itself; to send this phone's clipboard, use the Send clipboard to Mac " +
                "tile in Quick Settings.",
        )
        if (!link.adding) {
            FlatButton("Add another Mac", icon = Icons.Rounded.Add, primary = false, modifier = Modifier.fillMaxWidth(), onClick = actions.addMac)
        }
    }

    if (link.adding) {
        SectionLabel("Add a Mac")
        FlatBox {
            Text(
                "On the Mac, open Conduit → Devices → Add Phone. Macs appear here when they are on a network this " +
                    "phone can reach, or when your Mac is connected to this phone over adb.",
                color = canvas.contentSecondary,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(16.dp),
            )
            if (link.found.isEmpty()) {
                Line()
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), color = canvas.content, strokeWidth = 2.dp)
                    Spacer(Modifier.width(12.dp))
                    Text("Looking for Macs…", color = canvas.content, style = MaterialTheme.typography.bodyMedium)
                }
            }
            link.found.forEach { found ->
                Line()
                ItemRow(
                    found.name,
                    supporting = found.hosts.first(),
                    icon = Icons.Rounded.LaptopMac,
                    onClick = { actions.pair(found) },
                ) { TrailingText("Pair", color = canvas.content) }
            }
            (link.status as? LinkHub.Status.Failed)?.let {
                Line()
                Text(it.message, color = LocalStatusColors.current.error, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(16.dp))
            }
            (link.status as? LinkHub.Status.Connecting)?.let {
                Line()
                Text("Contacting ${it.macName}…", color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(16.dp))
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
private fun HotspotBox(hotspotAddress: String?, onOpen: (SystemScreen) -> Unit) {
    val canvas = LocalCanvas.current
    FlatBox {
        ItemRow(
            "Use this phone's hotspot",
            supporting = if (hotspotAddress != null) "Hotspot on at $hotspotAddress" else "Hotspot off",
            supportingColor = if (hotspotAddress != null) LocalStatusColors.current.connected else null,
            icon = Icons.Rounded.WifiTethering,
        )
        Line()
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
            HotspotStep(1, "On the Mac, while this phone is connected, open Conduit → Devices → Get Ready.")
            HotspotStep(2, "Turn this phone's hotspot on.")
            HotspotStep(3, "Join the Mac to the hotspot. Conduit finds the phone by itself.")
        }
        Line()
        ItemRow("Open hotspot settings", onClick = { onOpen(SystemScreen.HOTSPOT) }) { Chevron() }
    }
}

@Composable
private fun HotspotStep(number: Int, text: String) {
    val canvas = LocalCanvas.current
    Row(Modifier.padding(vertical = 3.dp)) {
        Text(
            "$number",
            color = canvas.contentTertiary,
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.width(20.dp),
        )
        Text(text, color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun SetupStep(number: Int, title: String, detail: String, done: Boolean) {
    val canvas = LocalCanvas.current
    val stepShape = RoundedCornerShape(6.dp)
    ItemRow(
        title,
        supporting = detail,
        modifier = Modifier.semantics(mergeDescendants = true) {},
        leading = {
            Box(
                Modifier
                    .size(26.dp)
                    .then(
                        if (done) {
                            Modifier.background(canvas.accent, stepShape)
                        } else {
                            Modifier.border(1.dp, canvas.line, stepShape)
                        },
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (done) {
                    Icon(Icons.Rounded.Check, contentDescription = null, tint = canvas.onAccent, modifier = Modifier.size(16.dp))
                } else {
                    Text("$number", color = canvas.contentSecondary, style = MaterialTheme.typography.labelMedium)
                }
            }
        },
    ) {
        Text(
            if (done) "On" else "Off",
            color = if (done) canvas.content else canvas.contentTertiary,
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.semantics { contentDescription = if (done) "On" else "Off" },
        )
    }
}

private enum class FeatureFilter(val label: String) { ALL("All"), AVAILABLE("Available"), PLANNED("Planned") }

/** Every Conduit feature and whether it works today, filterable. */
@Composable
fun FeaturesScreen() {
    val context = LocalContext.current
    var filter by rememberSaveable { mutableStateOf(FeatureFilter.ALL) }

    ScreenColumn("Features") {
        Segmented(FeatureFilter.entries, filter, label = { it.label }) { filter = it }
        Spacer(Modifier.height(4.dp))

        val shown = FeatureId.entries.filter { feature ->
            when (filter) {
                FeatureFilter.ALL -> true
                FeatureFilter.AVAILABLE -> feature in featuresAvailableToday
                FeatureFilter.PLANNED -> feature !in featuresAvailableToday
            }
        }
        FlatBox {
            shown.forEachIndexed { index, feature ->
                if (index > 0) Line()
                // The trackpad is the one feature with a screen of its own.
                val opens = feature == FeatureId.TRACKPAD
                ItemRow(
                    feature.title(),
                    supporting = feature.detail(),
                    icon = feature.icon(),
                    onClick = if (opens) {
                        { context.startActivity(Intent(context, TrackpadActivity::class.java)) }
                    } else {
                        null
                    },
                ) {
                    if (opens) {
                        Chevron()
                    } else {
                        AvailabilityTag(if (feature in featuresAvailableToday) Availability.AVAILABLE else Availability.PLANNED)
                    }
                }
            }
        }
        Footnote("Available features are started from Conduit for Mac while this phone is connected.")
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
    val link by LinkHub.state.collectAsState()
    var askForPermission by remember { mutableStateOf(false) }
    // Notification access is granted outside the app, and the apps that have
    // posted change as they post, so both are read again on every return.
    var notificationsOn by remember { mutableStateOf(NotificationRelay.isListening(context)) }
    var notificationApps by remember { mutableStateOf(NotificationApps.apps(context)) }
    LaunchedEffect(link.notificationsOn) {
        notificationsOn = NotificationRelay.isListening(context)
        notificationApps = NotificationApps.apps(context)
    }
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
        notificationsOn = notificationsOn,
        notificationApps = notificationApps,
        onAllowApp = { id, allowed ->
            NotificationApps.setAllowed(context, id, allowed)
            notificationApps = NotificationApps.apps(context)
        },
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
    notificationsOn: Boolean = false,
    notificationApps: List<NotificationApps.App> = emptyList(),
    onAllowApp: (String, Boolean) -> Unit = { _, _ -> },
) {
    val canvas = LocalCanvas.current

    ScreenColumn("Settings") {
        SectionLabel("Appearance")
        Segmented(ThemeMode.entries, themeMode, label = { it.label }, onSelect = onThemeMode)

        SectionLabel("Connection")
        FlatBox {
            SwitchRow(
                icon = Icons.Rounded.WifiTethering,
                title = "Wireless debugging",
                supporting = "Lets Conduit for Mac reach this phone over Wi-Fi.",
                checked = phone.wirelessDebugging,
                onCheckedChange = onWirelessDebugging,
            )
            Line()
            SwitchRow(
                icon = Icons.Rounded.Coffee,
                title = "Stay awake while charging",
                supporting = "Keeps the screen on while plugged in.",
                checked = phone.stayAwakeWhileCharging,
                onCheckedChange = onStayAwake,
            )
            Line()
            ItemRow(
                "Developer options",
                supporting = if (phone.canChange) {
                    "Conduit can change the switches above for you."
                } else {
                    "To use the switches above, click Allow in Conduit for Mac → Devices."
                },
                icon = Icons.Rounded.DeveloperMode,
                onClick = { onOpen(SystemScreen.DEVELOPER_OPTIONS) },
            ) { Chevron() }
        }

        SectionLabel("Notifications")
        FlatBox {
            ItemRow(
                "Notifications on your Mac",
                supporting = if (notificationsOn) {
                    "Your linked Mac shows what arrives here. Nothing ongoing, and nothing from an app " +
                        "switched off below, ever leaves this phone."
                } else {
                    "Android has to let Conduit see notifications before your Mac can show them. Tap to allow it."
                },
                icon = Icons.Rounded.Notifications,
                onClick = { onOpen(SystemScreen.NOTIFICATION_ACCESS) },
            ) {
                TrailingText(if (notificationsOn) "On" else "Off")
            }
            if (notificationsOn && notificationApps.isNotEmpty()) {
                notificationApps.forEach { app ->
                    Line()
                    SwitchRow(
                        icon = null,
                        title = app.name,
                        supporting = if (app.allowed) "Goes to your Mac" else "Stays on this phone",
                        checked = app.allowed,
                        onCheckedChange = { allowed -> onAllowApp(app.id, allowed) },
                    )
                }
            }
        }

        SectionLabel("Privacy")
        FlatBox {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "Conduit asks for each permission only when you use the feature that needs it. " +
                        "Nothing from this app is included in backups or device transfers.",
                    color = canvas.contentSecondary,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    "While Conduit for Mac mirrors this phone with its screen off, it turns on Conduit touch " +
                        "guard: an accessibility service that ignores touches on the phone and reads nothing " +
                        "on the screen. Pressing the power button turns it off.",
                    color = canvas.contentSecondary,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }

        SectionLabel("About")
        FlatBox {
            ItemRow(
                DesignTokens.Brand.NAME,
                supporting = "Version $version · ${DesignTokens.Brand.TAGLINE}",
                leading = { ConduitMark(32.dp) },
            )
        }
    }
}
