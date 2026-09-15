package com.khushi.conduit.ui

import android.content.Context
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf

enum class ThemeMode(val label: String) {
    SYSTEM("System"),
    LIGHT("Light"),
    DARK("Dark"),
}

/** App-only preferences. Excluded from backups like everything else. */
@Stable
class AppPreferences(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("conduit", Context.MODE_PRIVATE)

    var themeMode by mutableStateOf(
        ThemeMode.entries.firstOrNull { it.name == prefs.getString(KEY_THEME, null) } ?: ThemeMode.SYSTEM,
    )
        private set

    fun updateThemeMode(mode: ThemeMode) {
        themeMode = mode
        prefs.edit().putString(KEY_THEME, mode.name).apply()
    }

    private companion object {
        const val KEY_THEME = "themeMode"
    }
}

val LocalAppPreferences = staticCompositionLocalOf<AppPreferences> {
    error("AppPreferences not provided")
}
