package com.khushi.conduit.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khushi.conduit.core.design.ColorToken
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.design.TypeRole

/**
 * Conduit's Material 3 theme, built from the shared design tokens.
 *
 * Dynamic colour is deliberately off: the phone, the menu bar and the Mac
 * workspace use one brand palette, so the product reads as one thing across
 * all three. Everything else — components, motion, type scale structure —
 * stays Material.
 */
@Immutable
data class ConduitStatusColors(
    val connected: Color,
    val working: Color,
    val error: Color,
    val idle: Color,
    val flow: Color,
)

val LocalStatusColors = staticCompositionLocalOf {
    ConduitStatusColors(Color.Green, Color.Yellow, Color.Red, Color.Gray, Color.Cyan)
}

private fun ColorToken.resolve(dark: Boolean) = Color(if (dark) this.dark else light)

private fun scheme(dark: Boolean) = with(DesignTokens.Color) {
    val base = if (dark) darkColorScheme() else lightColorScheme()
    base.copy(
        primary = accent.resolve(dark),
        onPrimary = onAccent.resolve(dark),
        primaryContainer = accent.resolve(dark).copy(alpha = 0.16f),
        onPrimaryContainer = accent.resolve(dark),
        secondary = flow.resolve(dark),
        background = background.resolve(dark),
        onBackground = textPrimary.resolve(dark),
        surface = background.resolve(dark),
        onSurface = textPrimary.resolve(dark),
        surfaceVariant = surfaceMuted.resolve(dark),
        onSurfaceVariant = textSecondary.resolve(dark),
        surfaceContainerLowest = surface.resolve(dark),
        surfaceContainerLow = surface.resolve(dark),
        surfaceContainer = surfaceElevated.resolve(dark),
        surfaceContainerHigh = surfaceMuted.resolve(dark),
        outline = border.resolve(dark),
        outlineVariant = border.resolve(dark),
        error = statusError.resolve(dark),
    )
}

private fun TypeRole.style(): TextStyle = TextStyle(
    fontSize = sizeSp.sp,
    fontWeight = when (weight) {
        "medium" -> FontWeight.Medium
        "semibold" -> FontWeight.SemiBold
        "bold" -> FontWeight.Bold
        else -> FontWeight.Normal
    },
)

private val typography = with(DesignTokens.Typography) {
    Typography(
        displaySmall = display.style(),
        headlineSmall = title.style().copy(fontSize = 24.sp),
        titleLarge = title.style(),
        titleMedium = headline.style(),
        bodyLarge = body.style(),
        bodyMedium = callout.style(),
        bodySmall = caption.style(),
        labelLarge = callout.style().copy(fontWeight = FontWeight.Medium),
        labelMedium = caption.style().copy(fontWeight = FontWeight.Medium),
    )
}

private val shapes = with(DesignTokens.Radius) {
    Shapes(
        small = RoundedCornerShape(small.dp),
        medium = RoundedCornerShape(medium.dp),
        large = RoundedCornerShape(large.dp),
        extraLarge = RoundedCornerShape(extraLarge.dp),
    )
}

@Composable
fun ConduitTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val status = with(DesignTokens.Color) {
        ConduitStatusColors(
            connected = statusConnected.resolve(darkTheme),
            working = statusWorking.resolve(darkTheme),
            error = statusError.resolve(darkTheme),
            idle = statusIdle.resolve(darkTheme),
            flow = flow.resolve(darkTheme),
        )
    }
    CompositionLocalProvider(LocalStatusColors provides status) {
        MaterialTheme(colorScheme = scheme(darkTheme), typography = typography, shapes = shapes, content = content)
    }
}
