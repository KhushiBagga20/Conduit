package com.khushi.conduit.core.protocol

import java.io.ByteArrayOutputStream

/**
 * Conduit Link framing. Spec: Shared/Protocol/README.md §2.
 *
 *     [channel u8][type u8][length u32 BE][payload]
 *
 * No magic number and no resynchronisation: TCP neither drops nor reorders
 * bytes, so an unknown channel or type can only mean a bug, and guessing past
 * it would turn garbage into input events.
 */
enum class LinkChannel(val value: Int) {
    CONTROL(0),
    INPUT(1),
    SENSOR(2),
    HAPTIC(3),
    MEDIA(4),
    FILE(5);

    val maxPayloadSize: Int get() = if (this == CONTROL) 1 shl 20 else 4 shl 20

    /** Frame types defined in protocol v1. Reserved channels define none yet. */
    val knownTypes: Set<Int>
        get() = when (this) {
            CONTROL -> setOf(ControlType.HANDSHAKE, ControlType.ENVELOPE)
            INPUT -> InputType.entries.map { it.value }.toSet()
            HAPTIC -> setOf(HapticType.VIBRATE)
            SENSOR, MEDIA, FILE -> emptySet()
        }

    companion object {
        fun of(value: Int): LinkChannel? = entries.firstOrNull { it.value == value }
    }
}

object ControlType {
    /** Plaintext; only before the session is established. */
    const val HANDSHAKE = 0
    /** A sealed Envelope; only after. */
    const val ENVELOPE = 1
}

class Frame(val channel: LinkChannel, val type: Int, val payload: ByteArray = ByteArray(0)) {

    fun encode(): ByteArray {
        val out = ByteArrayOutputStream(HEADER_SIZE + payload.size)
        out.write(channel.value)
        out.write(type)
        val length = payload.size
        out.write(length ushr 24 and 0xFF)
        out.write(length ushr 16 and 0xFF)
        out.write(length ushr 8 and 0xFF)
        out.write(length and 0xFF)
        out.write(payload)
        return out.toByteArray()
    }

    override fun equals(other: Any?): Boolean =
        other is Frame && other.channel == channel && other.type == type && other.payload.contentEquals(payload)

    override fun hashCode(): Int = (channel.hashCode() * 31 + type) * 31 + payload.contentHashCode()

    override fun toString(): String = "Frame($channel, type=$type, ${payload.size} bytes)"

    companion object {
        const val HEADER_SIZE = 6
    }
}

class FrameException(val reason: Reason, message: String) : Exception(message) {
    enum class Reason { UNKNOWN_CHANNEL, UNKNOWN_TYPE, TOO_LARGE }
}

/**
 * Incremental frame decoder. TCP delivers arbitrary chunks, so bytes are
 * buffered and every complete frame is returned. After an error the decoder
 * refuses further input — the stream position can no longer be trusted.
 */
class FrameDecoder {
    private var buffer = ByteArray(0)
    var failure: FrameException? = null
        private set

    fun receive(data: ByteArray): List<Frame> {
        failure?.let { throw it }
        buffer += data

        val frames = mutableListOf<Frame>()
        var offset = 0
        while (buffer.size - offset >= Frame.HEADER_SIZE) {
            val rawChannel = buffer[offset].toInt() and 0xFF
            val type = buffer[offset + 1].toInt() and 0xFF
            val length = (buffer[offset + 2].toInt() and 0xFF shl 24) or
                (buffer[offset + 3].toInt() and 0xFF shl 16) or
                (buffer[offset + 4].toInt() and 0xFF shl 8) or
                (buffer[offset + 5].toInt() and 0xFF)

            val channel = LinkChannel.of(rawChannel)
                ?: fail(FrameException.Reason.UNKNOWN_CHANNEL, "unknown channel $rawChannel")
            if (type !in channel.knownTypes) fail(FrameException.Reason.UNKNOWN_TYPE, "unknown type $type on $channel")
            // A negative length means the u32 exceeded Int.MAX_VALUE: too large either way.
            if (length < 0 || length > channel.maxPayloadSize) {
                fail(FrameException.Reason.TOO_LARGE, "payload of $length bytes on $channel")
            }
            if (buffer.size - offset < Frame.HEADER_SIZE + length) break

            val start = offset + Frame.HEADER_SIZE
            frames += Frame(channel, type, buffer.copyOfRange(start, start + length))
            offset = start + length
        }
        buffer = buffer.copyOfRange(offset, buffer.size)
        return frames
    }

    private fun fail(reason: FrameException.Reason, message: String): Nothing {
        val error = FrameException(reason, message)
        failure = error
        buffer = ByteArray(0)
        throw error
    }
}
