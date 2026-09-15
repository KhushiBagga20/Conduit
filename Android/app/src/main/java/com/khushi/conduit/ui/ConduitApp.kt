package com.khushi.conduit.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Apps
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Home
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.khushi.conduit.ui.screens.ActivityScreen
import com.khushi.conduit.ui.screens.FeaturesScreen
import com.khushi.conduit.ui.screens.HomeScreen
import com.khushi.conduit.ui.screens.MacsScreen
import com.khushi.conduit.ui.screens.SettingsScreen

/** The five sections of Conduit for Android. */
enum class Destination(val route: String, val label: String, val icon: ImageVector) {
    HOME("home", "Home", Icons.Rounded.Home),
    MACS("macs", "Macs", Icons.Rounded.LaptopMac),
    FEATURES("features", "Features", Icons.Rounded.Apps),
    ACTIVITY("activity", "Activity", Icons.Rounded.History),
    SETTINGS("settings", "Settings", Icons.Rounded.Settings),
}

@Composable
fun ConduitApp() {
    val navController = rememberNavController()
    val backStack by navController.currentBackStackEntryAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        bottomBar = {
            NavigationBar(containerColor = MaterialTheme.colorScheme.surfaceContainer) {
                Destination.entries.forEach { destination ->
                    val selected = backStack?.destination?.hierarchy?.any { it.route == destination.route } == true
                    NavigationBarItem(
                        selected = selected,
                        onClick = {
                            navController.navigate(destination.route) {
                                popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = { Icon(destination.icon, contentDescription = null) },
                        label = { Text(destination.label) },
                    )
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = Destination.HOME.route,
            modifier = Modifier.padding(padding),
        ) {
            composable(Destination.HOME.route) { HomeScreen() }
            composable(Destination.MACS.route) { MacsScreen() }
            composable(Destination.FEATURES.route) { FeaturesScreen() }
            composable(Destination.ACTIVITY.route) { ActivityScreen() }
            composable(Destination.SETTINGS.route) { SettingsScreen() }
        }
    }
}
