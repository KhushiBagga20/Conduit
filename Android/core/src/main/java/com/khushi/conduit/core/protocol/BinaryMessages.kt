package com.khushi.conduit.core.protocol

import java.nio.BufferUnderflowException
import java.nio.ByteBuffer

/**
 * Bodies for the binary channels. Spec: Shared/Protocol/README.md §7.
 * Input is binary rather than JSON because of rate: a trackpad drag is a
 * stream of 10-byte frames, and JSON would multiply that for no benefit.
 */
enum class InputType(val value: Int) {
    POINTER_MOVE(0),
    POINTER_BUTTON(1),
    SCROLL(2),
    KEY(3),
}

enum class PointerButton(val value: Int) { LEFT(0), RIGHT(1), MIDDLE(2) }

/** A physical control on the phone, by intent rather than Android keycode. */
enum class PhoneKey(val value: Int) { VOLUME_UP(0), VOLUME_DOWN(1) }

sealed class InputEvent {
    /** Relative movement: the phone cannot know the Mac's desktop size. */
    data class Move(val dx: Short, val dy: Short) : InputEvent()
    data class Button(val button: PointerButton, val down: Boolean) : InputEvent()
    data class Scroll(val dx: Short, val dy: Short) : InputEvent()
    data class Key(val key: PhoneKey, val down: Boolean) : InputEvent()

    fun toFrame(): Frame = when (this) {
        is Move -> Frame(LinkChannel.INPUT, InputType.POINTER_MOVE.value,
            ByteBuffer.allocate(4).putShort(dx).putShort(dy).array())
        is Button -> Frame(LinkChannel.INPUT, InputType.POINTER_BUTTON.value,
            byteArrayOf(button.value.toByte(), if (down) 1 else 0))
        is Scroll -> Frame(LinkChannel.INPUT, InputType.SCROLL.value,
            ByteBuffer.allocate(4).putShort(dx).putShort(dy).array())
        is Key -> Frame(LinkChannel.INPUT, InputType.KEY.value,
            ByteBuffer.allocate(3).putShort(key.value.toShort()).put(if (down) 1 else 0).array())
    }

    companion object {
        /** Decode an input frame; null for a malformed body rather than a crash. */
        fun from(frame: Frame): InputEvent? {
            if (frame.channel != LinkChannel.INPUT) return null
            val body = ByteBuffer.wrap(frame.payload)
            return try {
                when (frame.type) {
                    InputType.POINTER_MOVE.value -> Move(body.short, body.short)
                    InputType.POINTER_BUTTON.value -> {
                        // Read before matching: a read inside the predicate
                        // would consume a byte per candidate.
                        val raw = body.get().toInt()
                        val button = PointerButton.entries.firstOrNull { it.value == raw } ?: return null
                        Button(button, body.get().toInt() != 0)
                    }
                    InputType.SCROLL.value -> Scroll(body.short, body.short)
                    InputType.KEY.value -> {
                        val raw = body.short.toInt()
                        val key = PhoneKey.entries.firstOrNull { it.value == raw } ?: return null
                        Key(key, body.get().toInt() != 0)
                    }
                    else -> null
                }
            } catch (_: BufferUnderflowException) {
                null
            }
        }
    }
}

object HapticType {
    const val VIBRATE = 0
}

data class Vibration(val durationMs: Int, val amplitude: Int) {
    fun toFrame(): Frame = Frame(LinkChannel.HAPTIC, HapticType.VIBRATE,
        ByteBuffer.allocate(3).putShort(durationMs.toShort()).put(amplitude.coerceIn(1, 255).toByte()).array())

    companion object {
        fun from(frame: Frame): Vibration? {
            if (frame.channel != LinkChannel.HAPTIC || frame.type != HapticType.VIBRATE) return null
            if (frame.payload.size < 3) return null
            val body = ByteBuffer.wrap(frame.payload)
            return Vibration(body.short.toInt() and 0xFFFF, body.get().toInt() and 0xFF)
        }
    }
}

object FileType {
    const val CHUNK = 0
}

/**
 * A piece of a file whose `file.offer` was accepted. [transferId] is an
 * unsigned 32-bit number on the wire. The offset is where the bytes belong;
 * TCP keeps them in order, so it only catches bugs.
 */
class FileChunk(val transferId: Int, val offset: Long, val bytes: ByteArray) {

    fun toFrame(): Frame = frame(transferId, offset, bytes, bytes.size)

    override fun equals(other: Any?): Boolean = other is FileChunk && other.transferId == transferId &&
        other.offset == offset && other.bytes.contentEquals(bytes)

    override fun hashCode(): Int = (transferId * 31 + offset.hashCode()) * 31 + bytes.contentHashCode()

    companion object {
        const val HEADER_SIZE = 12

        /** The first [length] bytes of [buffer], without copying them twice. */
        fun frame(transferId: Int, offset: Long, buffer: ByteArray, length: Int): Frame =
            Frame(LinkChannel.FILE, FileType.CHUNK,
                ByteBuffer.allocate(HEADER_SIZE + length).putInt(transferId).putLong(offset).put(buffer, 0, length).array())

        fun from(frame: Frame): FileChunk? {
            if (frame.channel != LinkChannel.FILE || frame.type != FileType.CHUNK) return null
            if (frame.payload.size < HEADER_SIZE) return null
            val body = ByteBuffer.wrap(frame.payload)
            return FileChunk(body.int, body.long, frame.payload.copyOfRange(HEADER_SIZE, frame.payload.size))
        }
    }
}
