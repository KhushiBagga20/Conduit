package com.khushi.conduit.ui

import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.khushi.conduit.ui.screens.FeaturesScreen
import com.khushi.conduit.ui.screens.HomeScreen
import com.khushi.conduit.ui.screens.MacsScreen
import com.khushi.conduit.ui.screens.SettingsScreen
import com.khushi.conduit.ui.theme.LocalCanvas

/** The four sections of Conduit for Android. */
enum class Destination(val route: String, val label: String, val icon: ImageVector) {
    HOME("home", "Home", Icons.Rounded.Home),
    MACS("macs", "Macs", Icons.Rounded.LaptopMac),
    FEATURES("features", "Features", Icons.Rounded.Apps),
    SETTINGS("settings", "Settings", Icons.Rounded.Settings),
}

/** The app frame: the current section above a flat bar to move between them. */
@Composable
fun ConduitApp() {
    val navController = rememberNavController()
    val backStack by navController.currentBackStackEntryAsState()
    val current = Destination.entries.firstOrNull { destination ->
        backStack?.destination?.hierarchy?.any { it.route == destination.route } == true
    } ?: Destination.HOME

    AppFrame(
        current = current,
        onSelect = { destination ->
            navController.navigate(destination.route) {
                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                launchSingleTop = true
                restoreState = true
            }
        },
    ) {
        NavHost(
            navController = navController,
            startDestination = Destination.HOME.route,
            modifier = Modifier.fillMaxSize(),
            enterTransition = { fadeIn(tween(160)) },
            exitTransition = { fadeOut(tween(120)) },
        ) {
            composable(Destination.HOME.route) { HomeScreen() }
            composable(Destination.MACS.route) { MacsScreen() }
            composable(Destination.FEATURES.route) { FeaturesScreen() }
            composable(Destination.SETTINGS.route) { SettingsScreen() }
        }
    }
}

/** A section's content above the bar, on a solid ground. */
@Composable
internal fun AppFrame(current: Destination, onSelect: (Destination) -> Unit, content: @Composable () -> Unit) {
    val canvas = LocalCanvas.current
    Column(Modifier.fillMaxSize().background(canvas.background)) {
        Box(Modifier.weight(1f).fillMaxWidth()) { content() }
        NavBar(current = current, onSelect = onSelect)
    }
}

/** Flat tabs under a hairline: the icon, and its name beneath. */
@Composable
internal fun NavBar(current: Destination, onSelect: (Destination) -> Unit) {
    val canvas = LocalCanvas.current
    Column(Modifier.fillMaxWidth().background(canvas.background)) {
        HorizontalDivider(thickness = 1.dp, color = canvas.line)
        Row(Modifier.fillMaxWidth().navigationBarsPadding().height(62.dp)) {
            Destination.entries.forEach { destination ->
                val selected = destination == current
                val ink = if (selected) canvas.content else canvas.contentTertiary
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .selectable(selected = selected, role = Role.Tab, onClick = { onSelect(destination) }),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(destination.icon, contentDescription = null, tint = ink, modifier = Modifier.size(22.dp))
                    Spacer(Modifier.height(3.dp))
                    Text(destination.label, color = ink, style = MaterialTheme.typography.labelMedium, maxLines = 1)
                }
            }
        }
    }
}
