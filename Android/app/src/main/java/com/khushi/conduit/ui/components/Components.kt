package com.khushi.conduit.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.Cast
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Description
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.MusicNote
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.PhotoCamera
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.khushi.conduit.core.design.DesignTokens
import com.khushi.conduit.core.protocol.Availability
import com.khushi.conduit.core.protocol.FeatureId
import com.khushi.conduit.ui.theme.LocalStatusColors

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

/**
 * Says why a feature cannot be used — Planned, Requires permission, Needs
 * setup, Not supported on this device — instead of a control that silently
 * does nothing.
 */
@Composable
fun AvailabilityChip(availability: Availability) {
    val status = LocalStatusColors.current
    val color = when (availability) {
        Availability.AVAILABLE, Availability.ACTIVE -> status.connected
        Availability.REQUIRES_PERMISSION, Availability.REQUIRES_SETUP -> status.working
        Availability.UNSUPPORTED -> status.error
        Availability.DISABLED, Availability.PLANNED -> MaterialTheme.colorScheme.onSurfaceVariant
    }
    Text(
        text = DesignTokens.availabilityLabel[availability.wire] ?: availability.wire,
        style = MaterialTheme.typography.labelMedium,
        color = color,
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), CircleShape)
            .padding(horizontal = DesignTokens.Spacing.s.dp, vertical = DesignTokens.Spacing.xxs.dp),
    )
}

/** Conduit's card: a quiet surface with a hairline border. */
@Composable
fun ConduitCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .border(1.dp, MaterialTheme.colorScheme.outline, MaterialTheme.shapes.large),
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surfaceContainerLowest,
    ) {
        Column(Modifier.padding(DesignTokens.Spacing.l.dp), content = content)
    }
}

@Composable
fun SectionHeader(title: String, detail: String? = null) {
    Column(Modifier.padding(top = DesignTokens.Spacing.s.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        if (detail != null) {
            Text(detail, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** A square action that shows its availability when it cannot run. */
@Composable
fun QuickActionTile(
    title: String,
    icon: ImageVector,
    availability: Availability,
    modifier: Modifier = Modifier,
    onClick: () -> Unit = {},
) {
    val usable = availability.isUsable
    Surface(
        onClick = onClick,
        enabled = usable,
        modifier = modifier.height(96.dp),
        shape = MaterialTheme.shapes.medium,
        color = if (usable) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant,
    ) {
        Column(
            Modifier.padding(DesignTokens.Spacing.m.dp).alpha(if (usable) 1f else 0.6f),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Icon(icon, contentDescription = null,
                tint = if (usable) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(DesignTokens.Spacing.xs.dp))
            Text(title, style = MaterialTheme.typography.labelLarge, textAlign = TextAlign.Center, maxLines = 1)
            if (!usable) {
                Text(DesignTokens.availabilityLabel[availability.wire] ?: "",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
fun EmptyState(icon: ImageVector, title: String, message: String, modifier: Modifier = Modifier,
               action: @Composable (() -> Unit)? = null) {
    Column(
        modifier.fillMaxWidth().padding(DesignTokens.Spacing.xxl.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.m.dp),
    ) {
        Box(
            Modifier.size(88.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(40.dp))
        }
        Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Text(message, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        action?.invoke()
    }
}

/** Conduit's mark: two nodes joined by a flowing line, on the brand gradient. */
@Composable
fun ConduitMark(size: Dp = 32.dp) {
    val colors = listOf(MaterialTheme.colorScheme.primary, LocalStatusColors.current.flow)
    Box(
        Modifier
            .size(size)
            .background(Brush.linearGradient(colors), MaterialTheme.shapes.small),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(size * 0.62f)) {
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
