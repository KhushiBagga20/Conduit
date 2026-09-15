package com.khushi.conduit.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.khushi.conduit.ui.components.GlassPanel
import com.khushi.conduit.ui.components.dotGrid
import com.khushi.conduit.ui.screens.ActivityScreen
import com.khushi.conduit.ui.screens.FeaturesScreen
import com.khushi.conduit.ui.screens.HomeScreen
import com.khushi.conduit.ui.screens.MacsScreen
import com.khushi.conduit.ui.screens.SettingsScreen
import com.khushi.conduit.ui.theme.LocalCanvas

/** The five sections of Conduit for Android. */
enum class Destination(val route: String, val label: String, val icon: ImageVector) {
    HOME("home", "Home", Icons.Rounded.Home),
    MACS("macs", "Macs", Icons.Rounded.LaptopMac),
    FEATURES("features", "Features", Icons.Rounded.Apps),
    ACTIVITY("activity", "Activity", Icons.Rounded.History),
    SETTINGS("settings", "Settings", Icons.Rounded.Settings),
}

/**
 * The app frame: a dotted canvas edge to edge, the current section, and a
 * floating bar to move between sections.
 */
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
            enterTransition = { fadeIn(tween(220)) },
            exitTransition = { fadeOut(tween(160)) },
        ) {
            composable(Destination.HOME.route) { HomeScreen() }
            composable(Destination.MACS.route) { MacsScreen() }
            composable(Destination.FEATURES.route) { FeaturesScreen() }
            composable(Destination.ACTIVITY.route) { ActivityScreen() }
            composable(Destination.SETTINGS.route) { SettingsScreen() }
        }
    }
}

/** The dotted canvas, a section's content, and the floating bar over it. */
@Composable
internal fun AppFrame(current: Destination, onSelect: (Destination) -> Unit, content: @Composable () -> Unit) {
    val canvas = LocalCanvas.current
    Box(
        Modifier
            .fillMaxSize()
            .background(canvas.background)
            .dotGrid(canvas.grid, pitch = 18.dp, radius = 1.dp),
    ) {
        content()

        // Content fades out before it reaches the bar.
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Color.Transparent, canvas.background.copy(alpha = 0.92f)))),
        ) {
            Spacer(Modifier.fillMaxWidth().padding(top = 96.dp).windowInsetsBottomHeight(WindowInsets.navigationBars))
        }

        FloatingNavBar(
            current = current,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 14.dp),
            onSelect = onSelect,
        )
    }
}

@Composable
internal fun FloatingNavBar(current: Destination, modifier: Modifier = Modifier, onSelect: (Destination) -> Unit) {
    val canvas = LocalCanvas.current
    GlassPanel(modifier.height(64.dp)) {
        Spacer(Modifier.width(8.dp))
        Destination.entries.forEach { destination ->
            val selected = destination == current
            Row(
                Modifier
                    .height(48.dp)
                    .clip(CircleShape)
                    .background(if (selected) canvas.content else Color.Transparent)
                    .selectable(selected = selected, role = Role.Tab, onClick = { onSelect(destination) })
                    .animateContentSize()
                    .padding(horizontal = if (selected) 16.dp else 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    destination.icon,
                    contentDescription = if (selected) null else destination.label,
                    tint = if (selected) canvas.background else canvas.contentSecondary,
                )
                if (selected) {
                    Spacer(Modifier.width(8.dp))
                    Text(destination.label, color = canvas.background, style = MaterialTheme.typography.labelLarge, maxLines = 1)
                }
            }
            Spacer(Modifier.width(2.dp))
        }
        Spacer(Modifier.width(6.dp))
    }
}
