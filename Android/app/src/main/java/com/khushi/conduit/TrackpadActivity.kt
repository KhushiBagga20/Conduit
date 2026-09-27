package com.khushi.conduit

import android.graphics.Color
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import com.khushi.conduit.link.LinkService
import com.khushi.conduit.ui.AppPreferences
import com.khushi.conduit.ui.LocalAppPreferences
import com.khushi.conduit.ui.ThemeMode
import com.khushi.conduit.ui.screens.TrackpadScreen
import com.khushi.conduit.ui.theme.ConduitTheme

/**
 * The trackpad on its own screen: the pointer follows the finger, so the
 * display must stay awake and nothing else should be in the way.
 */
class TrackpadActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        LinkService.ensureRunning(this)
        enableEdgeToEdge()
        setContent {
            val preferences = remember { AppPreferences(this) }
            val dark = when (preferences.themeMode) {
                ThemeMode.SYSTEM -> isSystemInDarkTheme()
                ThemeMode.LIGHT -> false
                ThemeMode.DARK -> true
            }
            DisposableEffect(dark) {
                val style = if (dark) {
                    SystemBarStyle.dark(Color.TRANSPARENT)
                } else {
                    SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                }
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
                onDispose { }
            }
            CompositionLocalProvider(LocalAppPreferences provides preferences) {
                ConduitTheme(darkTheme = dark) {
                    TrackpadScreen(onDone = { finish() })
                }
            }
        }
    }
}
