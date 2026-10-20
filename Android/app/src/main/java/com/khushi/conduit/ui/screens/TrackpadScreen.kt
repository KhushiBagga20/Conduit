package com.khushi.conduit.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.khushi.conduit.core.protocol.InputEvent
import com.khushi.conduit.core.protocol.PointerButton
import com.khushi.conduit.link.LinkHub
import com.khushi.conduit.link.LinkService
import com.khushi.conduit.ui.components.BoxShape
import com.khushi.conduit.ui.components.FlatButton
import com.khushi.conduit.ui.theme.LocalCanvas
import com.khushi.conduit.ui.theme.LocalStatusColors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * This phone as the Mac's trackpad — Shared/Protocol/README.md §7.
 *
 * Movement is relative and measured in density-independent points, so the
 * Mac's pointer speed setting means the same thing on every phone. Fractions
 * are carried between frames: rounding each one away would lose most of a
 * slow, careful movement.
 */
@Composable
fun TrackpadScreen(onDone: () -> Unit) {
    val canvas = LocalCanvas.current
    val link by LinkHub.state.collectAsState()
    val mac = link.linked.firstOrNull { it.id == link.connectedId }

    // The Mac says whether it will take the trackpad at all: it drops every
    // touch until macOS allows Conduit to move the pointer, and swiping at
    // nothing is no way to find that out.
    var refusal by remember { mutableStateOf<String?>(null) }
    var asking by remember { mutableStateOf(true) }
    DisposableEffect(link.connectedId) {
        asking = true
        refusal = null
        LinkService.startTrackpad { error ->
            asking = false
            refusal = error?.message
        }
        onDispose { LinkService.stopTrackpad() }
    }
    val ready = mac != null && !asking && refusal == null

    Column(
        Modifier
            .fillMaxSize()
            .background(canvas.background)
            .systemBarsPadding(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("Trackpad", color = canvas.content, style = MaterialTheme.typography.headlineSmall)
                Text(
                    when {
                        mac == null -> "Not linked to a Mac right now"
                        asking -> "Asking your Mac…"
                        refusal != null -> "Your Mac is not taking the trackpad"
                        else -> "Moving the pointer on ${mac.name}"
                    },
                    color = when {
                        refusal != null -> LocalStatusColors.current.error
                        ready -> LocalStatusColors.current.connected
                        else -> canvas.contentSecondary
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            TextButton(onClick = onDone) { Text("Done", color = canvas.content) }
        }

        TrackpadSurface(Modifier.weight(1f).fillMaxWidth().padding(16.dp), enabled = ready, refusal = refusal)

        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            FlatButton("Click", Modifier.weight(1f), primary = false) { click(PointerButton.LEFT) }
            FlatButton("Right click", Modifier.weight(1f), primary = false) { click(PointerButton.RIGHT) }
        }

        Text(
            "One finger moves the pointer · tap to click · two fingers scroll · two-finger tap right-clicks · " +
                "tap then hold to drag",
            color = canvas.contentSecondary,
            style = MaterialTheme.typography.bodySmall,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 14.dp),
        )
    }
}

private fun click(button: PointerButton) {
    LinkService.input(InputEvent.Button(button, true))
    LinkService.input(InputEvent.Button(button, false))
}

/** The surface itself: every touch on it belongs to the Mac. */
@Composable
private fun TrackpadSurface(modifier: Modifier, enabled: Boolean, refusal: String?) {
    val canvas = LocalCanvas.current
    val density = LocalDensity.current.density

    Box(
        modifier
            .clip(BoxShape)
            .background(canvas.surface)
            .border(1.dp, canvas.line, BoxShape)
            .pointerInput(enabled, density) {
                if (!enabled) return@pointerInput
                val slop = viewConfiguration.touchSlop * 1.6f
                var lastTapEndedAt = 0L

                awaitEachGesture {
                    var pointers = 0
                    var travelled = 0f
                    var carry = Offset.Zero
                    val startedAt = System.currentTimeMillis()

                    // A tap and then a press within a moment is a drag: the
                    // Mac holds the button down for as long as this gesture.
                    val dragging = startedAt - lastTapEndedAt < DRAG_WINDOW_MS
                    if (dragging) LinkService.input(InputEvent.Button(PointerButton.LEFT, true))

                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break
                        pointers = max(pointers, pressed.size)

                        val delta = movement(pressed)
                        travelled += delta.getDistance()
                        val moved = (delta / density) + carry
                        val x = moved.x.roundToInt()
                        val y = moved.y.roundToInt()
                        carry = Offset(moved.x - x, moved.y - y)

                        if (x != 0 || y != 0) {
                            LinkService.input(
                                if (pressed.size == 1) {
                                    InputEvent.Move(x.short(), y.short())
                                } else {
                                    InputEvent.Scroll(x.short(), y.short())
                                },
                            )
                        }
                        event.changes.forEach { it.consume() }
                    }

                    val held = System.currentTimeMillis() - startedAt
                    when {
                        dragging -> LinkService.input(InputEvent.Button(PointerButton.LEFT, false))
                        travelled > slop || held > TAP_MILLIS -> Unit
                        pointers == 1 -> {
                            click(PointerButton.LEFT)
                            lastTapEndedAt = System.currentTimeMillis()
                        }
                        pointers == 2 -> click(PointerButton.RIGHT)
                        pointers >= 3 -> click(PointerButton.MIDDLE)
                    }
                }
            },
    ) {
        if (!enabled) {
            Column(
                Modifier.align(Alignment.Center).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    if (refusal != null) "Your Mac won't take it yet" else "No Mac to move",
                    color = canvas.content,
                    style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    refusal ?: "Link a Mac, and keep it on a network this phone can reach.",
                    color = canvas.contentSecondary,
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                )
            }
        } else {
            Spacer(Modifier.width(0.dp))
        }
    }
}

/** One finger: how far it moved. More: how far they moved together. */
private fun movement(pressed: List<PointerInputChange>): Offset =
    pressed.fold(Offset.Zero) { sum, change -> sum + change.positionChange() } / pressed.size.toFloat()

/** The wire carries i16; a single frame never needs more than this anyway. */
private fun Int.short(): Short = coerceIn(-30_000, 30_000).toShort()

private const val TAP_MILLIS = 320L
private const val DRAG_WINDOW_MS = 320L
