package com.khushi.conduit.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
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
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
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
import com.khushi.conduit.ui.theme.LocalCanvas
import com.khushi.conduit.ui.theme.LocalStatusColors

// The flat vocabulary of Conduit for Android: boxes edged with a hairline,
// rows divided by lines, plain icons, and one monochrome accent. Nothing
// glows, nothing floats; colour appears only where it means something.

val BoxShape = RoundedCornerShape(12.dp)
val ButtonShape = RoundedCornerShape(10.dp)
private val TagShape = RoundedCornerShape(6.dp)

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

/** A box: rows inside it are divided by [Line]. */
@Composable
fun FlatBox(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val canvas = LocalCanvas.current
    Column(
        modifier
            .fillMaxWidth()
            .clip(BoxShape)
            .background(canvas.surface)
            .border(1.dp, canvas.line, BoxShape),
        content = content,
    )
}

/** The hairline between rows. */
@Composable
fun Line(modifier: Modifier = Modifier) {
    HorizontalDivider(modifier, thickness = 1.dp, color = LocalCanvas.current.line)
}

/** Breathing room at the end of a scrolling screen. */
@Composable
fun BottomSpacer() {
    Spacer(Modifier.height(24.dp))
}

// Rows

/**
 * One row in a box: an icon, a title, a line of supporting text, and
 * whatever belongs at the end — a value, an action, a switch. The whole row
 * is the target when it does something.
 */
@Composable
fun ItemRow(
    title: String,
    modifier: Modifier = Modifier,
    supporting: String? = null,
    supportingColor: Color? = null,
    icon: ImageVector? = null,
    onClick: (() -> Unit)? = null,
    leading: (@Composable () -> Unit)? = null,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    val canvas = LocalCanvas.current
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            leading != null -> {
                leading()
                Spacer(Modifier.width(14.dp))
            }
            icon != null -> {
                Icon(icon, contentDescription = null, tint = canvas.content, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(16.dp))
            }
        }
        Column(Modifier.weight(1f)) {
            Text(
                title,
                color = canvas.content,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (supporting != null) {
                Text(
                    supporting,
                    color = supportingColor ?: canvas.contentSecondary,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        trailing()
    }
}

/** A value at the end of a row. */
@Composable
fun TrailingText(text: String, color: Color? = null) {
    Text(
        text,
        color = color ?: LocalCanvas.current.contentSecondary,
        style = MaterialTheme.typography.bodyMedium,
        maxLines = 1,
    )
}

/** Says a row goes somewhere. */
@Composable
fun Chevron() {
    Icon(
        Icons.AutoMirrored.Rounded.KeyboardArrowRight,
        contentDescription = null,
        tint = LocalCanvas.current.contentTertiary,
        modifier = Modifier.size(20.dp),
    )
}

/** A small text action at the end of a row. */
@Composable
fun RowAction(text: String, secondary: Boolean = false, onClick: () -> Unit) {
    val canvas = LocalCanvas.current
    TextButton(onClick = onClick, shape = ButtonShape) {
        Text(text, color = if (secondary) canvas.contentSecondary else canvas.content, style = MaterialTheme.typography.labelLarge)
    }
}

/** A row with a switch; the whole row toggles. */
@Composable
fun SwitchRow(
    icon: ImageVector?,
    title: String,
    supporting: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    ItemRow(
        title = title,
        supporting = supporting,
        icon = icon,
        modifier = Modifier.toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange),
    ) {
        Switch(checked = checked, onCheckedChange = null, colors = flatSwitchColors())
    }
}

@Composable
fun flatSwitchColors(): SwitchColors {
    val canvas = LocalCanvas.current
    return SwitchDefaults.colors(
        checkedThumbColor = canvas.onAccent,
        checkedTrackColor = canvas.accent,
        checkedBorderColor = canvas.accent,
        uncheckedThumbColor = canvas.contentTertiary,
        uncheckedTrackColor = canvas.background,
        uncheckedBorderColor = canvas.line,
    )
}

// Controls

/**
 * A flat button. The primary one is filled with the accent; the other is a
 * hairline outline.
 */
@Composable
fun FlatButton(
    text: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    primary: Boolean = true,
    onClick: () -> Unit,
) {
    val canvas = LocalCanvas.current
    val fill = if (primary) canvas.accent else Color.Transparent
    val ink = if (primary) canvas.onAccent else canvas.content
    Row(
        modifier
            .heightIn(min = 48.dp)
            .clip(ButtonShape)
            .background(fill)
            .then(if (primary) Modifier else Modifier.border(1.dp, canvas.line, ButtonShape))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = ink, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, color = ink, style = MaterialTheme.typography.labelLarge.copy(fontSize = 15.sp))
    }
}

/** A choice of a few, drawn as one box split into equal cells. */
@Composable
fun <T> Segmented(options: List<T>, selected: T, label: (T) -> String, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
    val canvas = LocalCanvas.current
    Row(
        modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(ButtonShape)
            .border(1.dp, canvas.line, ButtonShape),
    ) {
        options.forEachIndexed { index, option ->
            if (index > 0) VerticalDivider(Modifier.fillMaxHeight(), thickness = 1.dp, color = canvas.line)
            val isSelected = option == selected
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp)
                    .background(if (isSelected) canvas.accent else Color.Transparent)
                    .selectable(selected = isSelected, role = Role.Tab, onClick = { onSelect(option) }),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    label(option),
                    color = if (isSelected) canvas.onAccent else canvas.contentSecondary,
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 1,
                )
            }
        }
    }
}

/**
 * Whether a feature works today — Available, Planned, Requires permission —
 * as a small outlined tag, so nothing looks usable that is not.
 */
@Composable
fun AvailabilityTag(availability: Availability, modifier: Modifier = Modifier) {
    val status = LocalStatusColors.current
    val canvas = LocalCanvas.current
    val color = when (availability) {
        Availability.AVAILABLE, Availability.ACTIVE -> status.connected
        Availability.REQUIRES_PERMISSION, Availability.REQUIRES_SETUP -> status.working
        Availability.UNSUPPORTED -> status.error
        else -> canvas.contentSecondary
    }
    Text(
        text = DesignTokens.availabilityLabel[availability.wire] ?: availability.wire,
        style = MaterialTheme.typography.labelMedium,
        color = color,
        maxLines = 1,
        modifier = modifier
            .border(1.dp, color.copy(alpha = 0.5f), TagShape)
            .padding(horizontal = 8.dp, vertical = 3.dp),
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
            fontSize = 28.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = (-0.4).sp,
        ),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/** The small heading above a box. */
@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        modifier = modifier.padding(start = 4.dp, top = 16.dp, bottom = 2.dp),
        color = LocalCanvas.current.contentSecondary,
        style = MaterialTheme.typography.labelMedium.copy(letterSpacing = 0.8.sp),
    )
}

/** A note under a box. */
@Composable
fun Footnote(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier = modifier.padding(horizontal = 4.dp),
        color = LocalCanvas.current.contentSecondary,
        style = MaterialTheme.typography.bodySmall,
    )
}

// Empty and permission states

/** Nothing here yet: what this is, and the one thing to do about it. */
@Composable
fun EmptyState(
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    footer: @Composable () -> Unit = {},
) {
    val canvas = LocalCanvas.current
    FlatBox(modifier) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(title, color = canvas.content, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            Spacer(Modifier.height(6.dp))
            Text(
                message,
                color = canvas.contentSecondary,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(18.dp))
            footer()
        }
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

/** Conduit's mark: two nodes joined by a flowing line, drawn in one ink. */
@Composable
fun ConduitMark(size: Dp = 32.dp) {
    val canvas = LocalCanvas.current
    Box(
        Modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.28f))
            .border(1.dp, canvas.line, RoundedCornerShape(size * 0.28f)),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(size * 0.56f)) {
            val w = this.size.width
            val stroke = w * 0.1f
            val a = Offset(w * 0.22f, w * 0.22f)
            val b = Offset(w * 0.78f, w * 0.78f)
            val path = Path().apply {
                moveTo(a.x, a.y)
                cubicTo(w * 0.72f, a.y, w * 0.28f, b.y, b.x, b.y)
            }
            drawPath(path, canvas.content, style = Stroke(width = stroke, cap = StrokeCap.Round))
            drawCircle(canvas.content, radius = stroke * 1.2f, center = a)
            drawCircle(canvas.content, radius = stroke * 1.2f, center = b)
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

/** Features that work today, with Conduit for Mac. The rest are planned. */
val featuresAvailableToday = setOf(
    FeatureId.MIRRORING, FeatureId.REMOTE_INPUT, FeatureId.CLIPBOARD, FeatureId.AUDIO,
    FeatureId.LINKS, FeatureId.FIND_MAC, FeatureId.TRACKPAD, FeatureId.FILES,
)

fun FeatureId.detail(): String = when (this) {
    FeatureId.MIRRORING -> "See and use this phone on your Mac"
    FeatureId.REMOTE_INPUT -> "Your Mac's keyboard, mouse and trackpad"
    FeatureId.TRACKPAD -> "Use this phone as your Mac's trackpad and pointer"
    FeatureId.CLIPBOARD -> "Copy on one, paste on the other"
    FeatureId.CAMERA -> "This phone as your Mac's webcam"
    FeatureId.CALLS -> "Answer phone calls on your Mac"
    FeatureId.LINKS -> "Send a link to open on the other device"
    FeatureId.AUDIO -> "Phone sound plays on your Mac"
    FeatureId.FILES -> "Move files between phone and Mac"
    FeatureId.NOTIFICATIONS -> "Phone notifications on your Mac"
    FeatureId.FIND_MAC -> "Ring your Mac from this phone to find it"
}
