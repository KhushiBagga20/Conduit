package com.khushi.conduit.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The dot language of Conduit for Android: dot-matrix numbers, a dotted
 * background grid, a dotted sphere and dotted orbits. Everything is drawn —
 * no bundled font or image — so it scales cleanly and costs nothing.
 */

/** 5×7 glyphs; '1' is a lit dot. Narrow glyphs use fewer columns. */
private val glyphs: Map<Char, List<String>> = mapOf(
    '0' to listOf("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    '1' to listOf("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    '2' to listOf("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    '3' to listOf("11110", "00001", "00001", "01110", "00001", "00001", "11110"),
    '4' to listOf("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    '5' to listOf("11111", "10000", "11110", "00001", "00001", "10001", "01110"),
    '6' to listOf("00110", "01000", "10000", "11110", "10001", "10001", "01110"),
    '7' to listOf("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    '8' to listOf("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    '9' to listOf("01110", "10001", "10001", "01111", "00001", "00010", "01100"),
    '.' to listOf("00", "00", "00", "00", "00", "11", "11"),
    ':' to listOf("0", "0", "1", "0", "1", "0", "0"),
    '%' to listOf("11001", "11010", "00010", "00100", "01000", "01011", "10011"),
    '-' to listOf("000", "000", "000", "111", "000", "000", "000"),
    '/' to listOf("00001", "00010", "00010", "00100", "01000", "01000", "10000"),
    'O' to listOf("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    'N' to listOf("10001", "11001", "11001", "10101", "10011", "10011", "10001"),
    'F' to listOf("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    ' ' to listOf("00", "00", "00", "00", "00", "00", "00"),
)

/**
 * Text drawn as a dot matrix, like a transit display. `hollow` draws rings
 * instead of solid dots, for large numbers. The dots shrink when the text
 * would not otherwise fit the space it is given.
 */
@Composable
fun DotMatrixText(
    text: String,
    modifier: Modifier = Modifier,
    dotPitch: Dp = 6.dp,
    color: Color = Color.White,
    hollow: Boolean = true,
) {
    val rows = 7
    val columns = (text.sumOf { (glyphs[it] ?: glyphs[' ']!!).first().length + 1 } - 1).coerceAtLeast(1)

    Spacer(
        modifier
            .semantics { contentDescription = text }
            .layout { measurable, constraints ->
                val wanted = dotPitch.toPx()
                val fitting = if (constraints.hasBoundedWidth) constraints.maxWidth.toFloat() / columns else wanted
                val pitch = min(wanted, fitting)
                val width = (pitch * columns).roundToInt()
                val height = (pitch * rows).roundToInt()
                val placeable = measurable.measure(Constraints.fixed(width, height))
                layout(width, height) { placeable.place(0, 0) }
            }
            .drawBehind {
                val pitch = size.height / rows
                var column = 0
                text.forEach { char ->
                    val glyph = glyphs[char] ?: glyphs[' ']!!
                    glyph.forEachIndexed { row, bits ->
                        bits.forEachIndexed { offset, bit ->
                            if (bit == '1') {
                                val center = Offset((column + offset + 0.5f) * pitch, (row + 0.5f) * pitch)
                                if (hollow) {
                                    drawCircle(color, radius = pitch * 0.38f, center = center, style = Stroke(pitch * 0.16f))
                                } else {
                                    drawCircle(color, radius = pitch * 0.40f, center = center)
                                }
                            }
                        }
                    }
                    column += glyph.first().length + 1
                }
            },
    )
}

/**
 * A faint grid of dots behind a screen. One dot is drawn into a small tile
 * that repeats, so the whole grid is a single rectangle to draw.
 */
fun Modifier.dotGrid(color: Color, pitch: Dp = 14.dp, radius: Dp = 0.9.dp): Modifier = drawWithCache {
    val step = pitch.toPx().roundToInt().coerceAtLeast(2)
    val tile = ImageBitmap(step, step)
    androidx.compose.ui.graphics.Canvas(tile).drawCircle(
        Offset(step / 2f, step / 2f),
        radius.toPx(),
        Paint().apply {
            this.color = color
            isAntiAlias = true
        },
    )
    val brush = ShaderBrush(ImageShader(tile, TileMode.Repeated, TileMode.Repeated))
    onDrawBehind { drawRect(brush) }
}

/**
 * A globe of dots: rings of latitude projected onto a tilted sphere, the
 * near side lit and larger, the far side a faint ghost.
 */
@Composable
fun DottedSphere(modifier: Modifier = Modifier, color: Color = Color.White, diameter: Dp = 200.dp) {
    Canvas(modifier.size(diameter)) {
        val radius = size.minDimension / 2 * 0.94f
        val center = Offset(size.width / 2, size.height / 2)
        val tilt = Math.toRadians(-24.0)
        val maxDot = 1.9.dp.toPx()
        val minDot = 0.7.dp.toPx()

        for (latitude in -80..80 step 10) {
            val phi = Math.toRadians(latitude.toDouble())
            val count = (36 * cos(phi)).roundToInt().coerceAtLeast(6)
            repeat(count) { index ->
                val theta = 2 * Math.PI * index / count + Math.toRadians(8.0)
                val x = cos(phi) * sin(theta)
                val y = sin(phi)
                val z = cos(phi) * cos(theta)
                // Tip the globe toward the viewer so its top shows.
                val tiltedY = y * cos(tilt) - z * sin(tilt)
                val depth = (y * sin(tilt) + z * cos(tilt)).toFloat()
                val point = Offset(center.x + x.toFloat() * radius, center.y - tiltedY.toFloat() * radius)
                if (depth < 0f) {
                    drawCircle(color.copy(alpha = 0.07f), minDot, point)
                } else {
                    // Light from the upper left.
                    val light = (0.55f * depth + 0.45f * ((-x.toFloat() + tiltedY.toFloat()) * 0.5f + 0.5f)).coerceIn(0f, 1f)
                    drawCircle(
                        color.copy(alpha = 0.18f + 0.8f * light),
                        minDot + (maxDot - minDot) * depth,
                        point,
                    )
                }
            }
        }
    }
}

/** Dashed orbits with a few satellites, for the foot of a hero card. */
@Composable
fun Orbits(modifier: Modifier = Modifier, color: Color = Color.White) {
    Canvas(modifier) {
        val dash = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 5.dp.toPx()))
        val ringRadius = size.height * 0.95f
        val centers = listOf(0.28f, 0.5f, 0.72f).map { Offset(size.width * it, size.height * 1.05f) }
        centers.forEach { c ->
            drawCircle(color.copy(alpha = 0.22f), ringRadius, c, style = Stroke(1.dp.toPx(), pathEffect = dash))
        }
        listOf(210.0, 250.0, 300.0).zip(centers).forEach { (angle, c) ->
            val a = Math.toRadians(angle)
            drawCircle(color, 3.dp.toPx(), Offset(c.x + ringRadius * cos(a).toFloat(), c.y + ringRadius * sin(a).toFloat()))
        }
    }
}

/** A row of dots with the first `filled` lit and a highlighted marker. */
@Composable
fun DottedMeter(
    fraction: Float,
    modifier: Modifier = Modifier,
    dots: Int = 22,
    color: Color = Color.White,
    marker: Color = Color(0xFFD6F55B),
) {
    val lit = (fraction.coerceIn(0f, 1f) * dots).toInt()
    Canvas(modifier) {
        val step = size.width / dots
        val cy = size.height / 2
        repeat(dots) { index ->
            val cx = step * index + step / 2
            when {
                index == lit - 1 || (lit == 0 && index == 0) ->
                    drawRoundRect(
                        marker,
                        topLeft = Offset(cx - 1.5.dp.toPx(), cy - 6.dp.toPx()),
                        size = Size(3.dp.toPx(), 12.dp.toPx()),
                        cornerRadius = CornerRadius(2.dp.toPx()),
                    )
                index < lit -> drawCircle(color, 1.8.dp.toPx(), Offset(cx, cy))
                else -> drawCircle(color.copy(alpha = 0.25f), 1.4.dp.toPx(), Offset(cx, cy))
            }
        }
    }
}

/** Page indicator: a dot per page, the current one drawn as a short bar. */
@Composable
fun PageDots(count: Int, current: Int, modifier: Modifier = Modifier, color: Color = Color.White) {
    Row(modifier.semantics { contentDescription = "Page ${current + 1} of $count" }) {
        repeat(count) { index ->
            val selected = index == current
            Canvas(Modifier.size(width = if (selected) 24.dp else 12.dp, height = 6.dp)) {
                val gap = 6.dp.toPx()
                if (selected) {
                    drawRoundRect(
                        color,
                        size = Size(size.width - gap, size.height),
                        cornerRadius = CornerRadius(size.height / 2),
                    )
                } else {
                    drawCircle(color.copy(alpha = 0.3f), size.height / 2, Offset(size.height / 2, size.height / 2))
                }
            }
        }
    }
}
