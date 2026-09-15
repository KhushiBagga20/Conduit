package com.khushi.conduit

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import com.khushi.conduit.ui.AppPreferences
import com.khushi.conduit.ui.ConduitApp
import com.khushi.conduit.ui.LocalAppPreferences
import com.khushi.conduit.ui.ThemeMode
import com.khushi.conduit.ui.theme.ConduitTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val preferences = remember { AppPreferences(this) }
            val dark = when (preferences.themeMode) {
                ThemeMode.SYSTEM -> isSystemInDarkTheme()
                ThemeMode.LIGHT -> false
                ThemeMode.DARK -> true
            }
            CompositionLocalProvider(LocalAppPreferences provides preferences) {
                ConduitTheme(darkTheme = dark) {
                    ConduitApp()
                }
            }
        }
    }
}
