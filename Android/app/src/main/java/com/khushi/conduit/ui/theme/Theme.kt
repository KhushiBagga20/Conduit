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

/**
 * The canvas the Android interface is drawn on: a near-black (or soft white)
 * ground with a faint dot grid, glass panels, raised controls and one lime
 * highlight. Vivid gradient cards sit on top of it.
 */
@Immutable
data class CanvasPalette(
    val isDark: Boolean,
    val background: Color,
    val grid: Color,
    val glass: Color,
    val glassBorder: Color,
    val raised: Color,
    val content: Color,
    val contentSecondary: Color,
    val lime: Color,
)

val LocalCanvas = staticCompositionLocalOf { canvasPalette(dark = true) }

fun canvasPalette(dark: Boolean) = if (dark) {
    CanvasPalette(
        isDark = true,
        background = Color(0xFF050507),
        grid = Color.White.copy(alpha = 0.07f),
        glass = Color(0xFF15151B).copy(alpha = 0.92f),
        glassBorder = Color.White.copy(alpha = 0.08f),
        raised = Color(0xFF1B1B22),
        content = Color(0xFFF4F4F8),
        contentSecondary = Color.White.copy(alpha = 0.58f),
        lime = Color(0xFFD6F55B),
    )
} else {
    CanvasPalette(
        isDark = false,
        background = Color(0xFFF1F1F5),
        grid = Color.Black.copy(alpha = 0.07f),
        glass = Color.White.copy(alpha = 0.92f),
        glassBorder = Color.Black.copy(alpha = 0.06f),
        raised = Color.White,
        content = Color(0xFF121216),
        contentSecondary = Color.Black.copy(alpha = 0.55f),
        lime = Color(0xFF7FA21A),
    )
}

/** Card gradients, top to bottom. Text on them is always white. */
object CardGradients {
    val magenta = listOf(Color(0xFFE35CC9), Color(0xFF8A2FC4), Color(0xFF32105E))
    val indigo = listOf(Color(0xFF7472FF), Color(0xFF3C3CC8), Color(0xFF161761))
    val ember = listOf(Color(0xFFFF8A4C), Color(0xFFE44D2E), Color(0xFF6E1A10))
    val graphiteDark = listOf(Color(0xFF2B2B33), Color(0xFF131318))
    val graphiteLight = listOf(Color(0xFFFFFFFF), Color(0xFFE7E7EE))
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
    val canvas = canvasPalette(darkTheme)
    CompositionLocalProvider(LocalStatusColors provides status, LocalCanvas provides canvas) {
        MaterialTheme(
            colorScheme = scheme(darkTheme).copy(background = canvas.background, surface = canvas.background),
            typography = typography,
            shapes = shapes,
            content = content,
        )
    }
}
