package com.khushi.conduit.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.PhotoCamera
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchColors
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.ui.theme.CardGradients
import com.khushi.conduit.ui.theme.LocalCanvas
import com.khushi.conduit.ui.theme.LocalStatusColors

// Status

/** The four states every connection-shaped thing in Conduit can be in. */
enum class StatusTone { CONNECTED, WORKING, ERROR, IDLE }

@Composable
fun StatusTone.color(): Color = with(LocalStatusColors.current) {
    when (this@color) {
        StatusTone.CONNECTED -> connected
        StatusTone.WORKING -> working
        StatusTone.ERROR -> error
        StatusTone.IDLE -> idle
    }
}

@Composable
fun StatusDot(tone: StatusTone, size: Dp = 8.dp) {
    Box(Modifier.size(size).background(tone.color(), CircleShape))
}

// Surfaces

val HeroShape = RoundedCornerShape(40.dp)
val CardShape = RoundedCornerShape(28.dp)

/**
 * A vivid gradient card with light falling on its upper edge and a glow of
 * its own colour behind it — the signature surface of Conduit for Android.
 * Content on it is white.
 */
@Composable
fun GradientCard(
    colors: List<Color>,
    modifier: Modifier = Modifier,
    shape: Shape = CardShape,
    content: @Composable BoxScope.() -> Unit,
) {
    val glow = colors.getOrElse(1) { colors.first() }
    Box(
        modifier
            .shadow(20.dp, shape, ambientColor = glow, spotColor = glow)
            .clip(shape)
            .drawWithCache {
                val body = Brush.verticalGradient(colors)
                val sheen = Brush.radialGradient(
                    listOf(Color.White.copy(alpha = 0.30f), Color.Transparent),
                    center = Offset(size.width * 0.18f, 0f),
                    radius = (size.maxDimension * 0.8f).coerceAtLeast(1f),
                )
                onDrawBehind {
                    drawRect(body)
                    drawRect(sheen)
                }
            }
            .border(1.dp, Color.White.copy(alpha = 0.14f), shape),
        content = content,
    )
}

/** A quiet card on the canvas: graphite in the dark, soft white in the light. */
@Composable
fun PlainCard(
    modifier: Modifier = Modifier,
    padding: Dp = 20.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    val canvas = LocalCanvas.current
    Column(
        modifier
            .clip(CardShape)
            .background(Brush.verticalGradient(if (canvas.isDark) CardGradients.graphiteDark else CardGradients.graphiteLight))
            .border(1.dp, canvas.glassBorder, CardShape)
            .padding(padding),
        content = content,
    )
}

/** A frosted, floating panel — the navigation bar and segmented controls. */
@Composable
fun GlassPanel(
    modifier: Modifier = Modifier,
    shape: Shape = CircleShape,
    content: @Composable RowScope.() -> Unit,
) {
    val canvas = LocalCanvas.current
    Row(
        modifier
            .shadow(16.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
            .clip(shape)
            .background(canvas.glass)
            .border(1.dp, canvas.glassBorder, shape),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

@Composable
fun CardDivider() {
    HorizontalDivider(color = LocalCanvas.current.glassBorder)
}

/** Room at the end of a scrolling screen so nothing hides under the floating bar. */
@Composable
fun BottomBarSpacer() {
    Spacer(Modifier.navigationBarsPadding().height(104.dp))
}

// Controls

/** A round raised button with an icon. */
@Composable
fun CircleButton(
    icon: ImageVector,
    contentDescription: String,
    modifier: Modifier = Modifier,
    onGradient: Boolean = false,
    onClick: () -> Unit,
) {
    val canvas = LocalCanvas.current
    val fill = if (onGradient) Color.White.copy(alpha = 0.18f) else canvas.raised
    val border = if (onGradient) Color.White.copy(alpha = 0.22f) else canvas.glassBorder
    val tint = if (onGradient) Color.White else canvas.content
    Box(
        modifier
            .size(46.dp)
            .clip(CircleShape)
            .background(fill)
            .border(1.dp, border, CircleShape)
            .clickable(role = Role.Button, onClickLabel = contentDescription, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(22.dp))
    }
}

/** An icon in a soft circle, for list rows and card corners. */
@Composable
fun IconBubble(icon: ImageVector, modifier: Modifier = Modifier, onGradient: Boolean = false, size: Dp = 40.dp) {
    val canvas = LocalCanvas.current
    Box(
        modifier
            .size(size)
            .background(if (onGradient) Color.White.copy(alpha = 0.18f) else canvas.content.copy(alpha = 0.07f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = if (onGradient) Color.White else canvas.content, modifier = Modifier.size(size * 0.5f))
    }
}

/** A pill-shaped action. */
@Composable
fun PillButton(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null, onClick: () -> Unit) {
    val canvas = LocalCanvas.current
    Row(
        modifier
            .heightIn(min = 52.dp)
            .clip(CircleShape)
            .background(canvas.content)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 22.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = canvas.background, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(10.dp))
        }
        Text(text, color = canvas.background, style = MaterialTheme.typography.labelLarge.copy(fontSize = 15.sp))
    }
}

/** Segmented choice drawn as pills in a glass track. */
@Composable
fun <T> PillSegments(options: List<T>, selected: T, label: (T) -> String, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
    val canvas = LocalCanvas.current
    GlassPanel(modifier.fillMaxWidth().height(52.dp)) {
        Spacer(Modifier.width(4.dp))
        options.forEach { option ->
            val isSelected = option == selected
            val fill by animateColorAsState(if (isSelected) canvas.content else Color.Transparent, label = "segment")
            Box(
                Modifier
                    .weight(1f)
                    .height(44.dp)
                    .clip(CircleShape)
                    .background(fill)
                    .selectable(selected = isSelected, role = Role.Tab, onClick = { onSelect(option) }),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label(option),
                    color = if (isSelected) canvas.background else canvas.contentSecondary,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                )
            }
        }
        Spacer(Modifier.width(4.dp))
    }
}

/** Switch colours on a gradient card: a white knob on a translucent track. */
@Composable
fun gradientSwitchColors(): SwitchColors = SwitchDefaults.colors(
    checkedThumbColor = Color.White,
    checkedTrackColor = Color.White.copy(alpha = 0.34f),
    checkedBorderColor = Color.Transparent,
    uncheckedThumbColor = Color.White.copy(alpha = 0.85f),
    uncheckedTrackColor = Color.Black.copy(alpha = 0.25f),
    uncheckedBorderColor = Color.White.copy(alpha = 0.3f),
)

/** Switch colours on the canvas: lime when on. */
@Composable
fun canvasSwitchColors(): SwitchColors {
    val canvas = LocalCanvas.current
    return SwitchDefaults.colors(
        checkedThumbColor = canvas.background,
        checkedTrackColor = canvas.lime,
        checkedBorderColor = Color.Transparent,
        uncheckedThumbColor = canvas.contentSecondary,
        uncheckedTrackColor = canvas.raised,
        uncheckedBorderColor = canvas.content.copy(alpha = 0.18f),
    )
}

/**
 * A large toggle card: graphite while off, lit with its gradient while on.
 * The whole card is the switch. When Conduit is not yet allowed to change
 * the setting a lock shows, and tapping explains how to allow it.
 */
@Composable
fun ToggleCard(
    title: String,
    stateText: String,
    icon: ImageVector,
    checked: Boolean,
    colors: List<Color>,
    modifier: Modifier = Modifier,
    locked: Boolean = false,
    onCheckedChange: (Boolean) -> Unit,
) {
    val canvas = LocalCanvas.current
    val body: @Composable () -> Unit = {
        val onGradient = checked
        val content = if (onGradient) Color.White else canvas.content
        Column(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 150.dp)
                .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange)
                .padding(16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconBubble(icon, onGradient = onGradient)
                Spacer(Modifier.weight(1f))
                Switch(
                    checked = checked,
                    onCheckedChange = null,
                    colors = if (onGradient) gradientSwitchColors() else canvasSwitchColors(),
                )
            }
            Spacer(Modifier.height(18.dp))
            Text(
                title,
                color = content,
                style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.SemiBold),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (locked) {
                    Icon(
                        Icons.Rounded.Lock,
                        contentDescription = "Needs permission",
                        tint = content.copy(alpha = 0.7f),
                        modifier = Modifier.size(13.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                }
                Text(
                    stateText,
                    color = content.copy(alpha = 0.72f),
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
    if (checked) {
        GradientCard(colors, modifier) { body() }
    } else {
        PlainCard(modifier, padding = 0.dp) { body() }
    }
}

/** A settings row with a switch; the whole row toggles. */
@Composable
fun SwitchRow(
    icon: ImageVector,
    title: String,
    supporting: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val canvas = LocalCanvas.current
    Row(
        Modifier
            .fillMaxWidth()
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange)
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconBubble(icon)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = canvas.content, style = MaterialTheme.typography.titleMedium)
            Text(supporting, color = canvas.contentSecondary, style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = null, colors = canvasSwitchColors())
    }
}

/**
 * A status pill — Available, Planned, Requires permission — so nothing looks
 * usable that is not.
 */
@Composable
fun AvailabilityPill(availability: Availability, modifier: Modifier = Modifier, onGradient: Boolean = false) {
    val status = LocalStatusColors.current
    val canvas = LocalCanvas.current
    val color = when {
        onGradient -> Color.White
        availability == Availability.AVAILABLE || availability == Availability.ACTIVE -> status.connected
        availability == Availability.REQUIRES_PERMISSION || availability == Availability.REQUIRES_SETUP -> status.working
        availability == Availability.UNSUPPORTED -> status.error
        else -> canvas.contentSecondary
    }
    Text(
        text = DesignTokens.availabilityLabel[availability.wire] ?: availability.wire,
        style = MaterialTheme.typography.labelMedium,
        color = color,
        maxLines = 1,
        modifier = modifier
            .clip(CircleShape)
            .background(color.copy(alpha = if (onGradient) 0.2f else 0.13f))
            .padding(horizontal = 10.dp, vertical = 4.dp),
    )
}

// Text

@Composable
fun ScreenTitle(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier = modifier,
        color = LocalCanvas.current.content,
        style = MaterialTheme.typography.headlineSmall.copy(
            fontSize = 30.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = (-0.5).sp,
        ),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier = modifier.padding(start = 4.dp, top = 12.dp),
        color = LocalCanvas.current.contentSecondary,
        style = MaterialTheme.typography.labelLarge.copy(fontSize = 14.sp),
    )
}

// Empty and permission states

/** An empty state around a dotted sphere. */
@Composable
fun DottedEmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    footer: @Composable () -> Unit = {},
) {
    val canvas = LocalCanvas.current
    Column(modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        DottedSphere(color = canvas.content, diameter = 180.dp)
        Spacer(Modifier.height(20.dp))
        Text(title, color = canvas.content, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Spacer(Modifier.height(6.dp))
        Text(
            message,
            color = canvas.contentSecondary,
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 12.dp),
        )
        Spacer(Modifier.height(14.dp))
        footer()
    }
}

/**
 * Shown when a toggle needs WRITE_SECURE_SETTINGS, which Android only grants
 * over adb. Says exactly how to get it, and offers the manual route.
 */
@Composable
fun NeedsPermissionDialog(onOpenDeveloperOptions: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Rounded.Lock, contentDescription = null) },
        title = { Text("Allow Conduit to change this") },
        text = {
            Text(
                "Android only lets Conduit change developer settings after your Mac allows it. " +
                    "Connect this phone to your Mac, then in Conduit for Mac open Devices and click Allow " +
                    "next to Wireless debugging control.\n\nYou can also change it yourself in Developer options.",
            )
        },
        confirmButton = { TextButton(onClick = onOpenDeveloperOptions) { Text("Open Developer options") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Not now") } },
    )
}

// Brand

/** Conduit's mark: two nodes joined by a flowing line, on the brand gradient. */
@Composable
fun ConduitMark(size: Dp = 32.dp) {
    Box(
        Modifier
            .size(size)
            .background(Brush.linearGradient(CardGradients.magenta.take(2) + CardGradients.indigo.first()), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(size * 0.56f)) {
            val w = this.size.width
            val stroke = w * 0.11f
            val a = Offset(w * 0.22f, w * 0.22f)
            val b = Offset(w * 0.78f, w * 0.78f)
            val path = Path().apply {
                moveTo(a.x, a.y)
                cubicTo(w * 0.72f, a.y, w * 0.28f, b.y, b.x, b.y)
            }
            drawPath(path, Color.White, style = Stroke(width = stroke, cap = StrokeCap.Round))
            drawCircle(Color.White, radius = stroke * 1.15f, center = a)
            drawCircle(Color.White, radius = stroke * 1.15f, center = b)
        }
    }
}

fun FeatureId.icon(): ImageVector = when (this) {
    FeatureId.MIRRORING -> Icons.Rounded.Cast
    FeatureId.REMOTE_INPUT -> Icons.Rounded.Mouse
    FeatureId.TRACKPAD -> Icons.Rounded.TouchApp
    FeatureId.CLIPBOARD -> Icons.Rounded.ContentPaste
    FeatureId.CAMERA -> Icons.Rounded.PhotoCamera
    FeatureId.CALLS -> Icons.Rounded.Call
    FeatureId.LINKS -> Icons.Rounded.Link
    FeatureId.AUDIO -> Icons.Rounded.MusicNote
    FeatureId.FILES -> Icons.Rounded.Description
    FeatureId.NOTIFICATIONS -> Icons.Rounded.Notifications
    FeatureId.FIND_MAC -> Icons.Rounded.LaptopMac
}

fun FeatureId.title(): String =
    DesignTokens.Feature.all.firstOrNull { it.id == wire }?.title ?: wire

/** Features that work today, through Conduit for Mac. The rest are planned. */
val featuresAvailableToday = setOf(FeatureId.MIRRORING, FeatureId.REMOTE_INPUT, FeatureId.CLIPBOARD, FeatureId.AUDIO)

fun FeatureId.detail(): String = when (this) {
    FeatureId.MIRRORING -> "See and use this phone on your Mac"
    FeatureId.REMOTE_INPUT -> "Your Mac's keyboard, mouse and trackpad"
    FeatureId.TRACKPAD -> "Use this phone as your Mac's trackpad"
    FeatureId.CLIPBOARD -> "Copy on one, paste on the other"
    FeatureId.CAMERA -> "This phone as your Mac's webcam"
    FeatureId.CALLS -> "Answer phone calls on your Mac"
    FeatureId.LINKS -> "Send a link to open on the other device"
    FeatureId.AUDIO -> "Phone sound plays on your Mac"
    FeatureId.FILES -> "Move files between phone and Mac"
    FeatureId.NOTIFICATIONS -> "Phone notifications on your Mac"
    FeatureId.FIND_MAC -> "Ring your Mac from this phone"
}
