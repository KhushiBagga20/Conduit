package com.khushi.conduit.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * Runs the language-neutral vectors in Shared/Protocol/vectors — the same
 * files ConduitKit's Swift tests run. That is what keeps two
 * implementations one protocol.
 */
class VectorTest {

    private val vectors = File(System.getProperty("conduit.vectors") ?: "../../Shared/Protocol/vectors")

    private fun load(name: String): JsonObject =
        Json.parseToJsonElement(File(vectors, name).readText()).jsonObject

    private fun hex(text: String): ByteArray =
        ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    @Test
    fun validEnvelopesRoundTripToTheSameJsonValue() {
        val valid = load("envelopes.json")["valid"]!!.jsonArray
        assertTrue(valid.isNotEmpty())
        for (vector in valid.map { it.jsonObject }) {
            val name = vector["name"]!!.jsonPrimitive.content
            val input = vector["input"] ?: vector["json"]!!
            val expected = vector["json"]!!

            val envelope = Envelope.decode(input.toString())
            val reencoded = Json.parseToJsonElement(envelope.encode())
            assertEquals("vector: $name", expected, reencoded)
        }
    }

    @Test
    fun invalidEnvelopesAreRejected() {
        val invalid = load("envelopes.json")["invalid"]!!.jsonArray
        assertTrue(invalid.isNotEmpty())
        for (vector in invalid.map { it.jsonObject }) {
            val name = vector["name"]!!.jsonPrimitive.content
            try {
                Envelope.decode(vector["json"]!!.toString())
                fail("expected rejection: $name")
            } catch (_: ProtocolException) {
                // expected
            }
        }
    }

    @Test
    fun framesEncodeToTheVectorBytesAndDecodeBack() {
        val frames = load("frames.json")["frames"]!!.jsonArray
        assertTrue(frames.isNotEmpty())
        for (vector in frames.map { it.jsonObject }) {
            val name = vector["name"]!!.jsonPrimitive.content
            val channel = LinkChannel.of(vector["channel"]!!.jsonPrimitive.int)!!
            val frame = Frame(channel, vector["type"]!!.jsonPrimitive.int, hex(vector["payloadHex"]!!.jsonPrimitive.content))
            val bytes = hex(vector["frameHex"]!!.jsonPrimitive.content)

            assertTrue("encode: $name", frame.encode().contentEquals(bytes))
            assertEquals("decode: $name", listOf(frame), FrameDecoder().receive(bytes))
        }
    }

    @Test
    fun framesSplitAtEveryByteStillDecode() {
        val frames = load("frames.json")["frames"]!!.jsonArray
        val stream = frames.map { hex(it.jsonObject["frameHex"]!!.jsonPrimitive.content) }
            .fold(ByteArray(0)) { acc, bytes -> acc + bytes }

        val decoder = FrameDecoder()
        val decoded = stream.flatMap { decoder.receive(byteArrayOf(it)) }
        assertEquals(frames.size, decoded.size)
        assertTrue(decoded.map { it.encode() }.fold(ByteArray(0)) { acc, b -> acc + b }.contentEquals(stream))
    }

    @Test
    fun rejectedFramesFailAndPoisonTheDecoder() {
        val rejected = load("frames.json")["rejected"]!!.jsonArray as JsonArray
        for (vector in rejected.map { it.jsonObject }) {
            val name = vector["name"]!!.jsonPrimitive.content
            val expected = when (vector["reason"]!!.jsonPrimitive.content) {
                "unknown_channel" -> FrameException.Reason.UNKNOWN_CHANNEL
                "unknown_type" -> FrameException.Reason.UNKNOWN_TYPE
                else -> FrameException.Reason.TOO_LARGE
            }
            val decoder = FrameDecoder()
            try {
                decoder.receive(hex(vector["hex"]!!.jsonPrimitive.content))
                fail("expected rejection: $name")
            } catch (error: FrameException) {
                assertEquals("reason: $name", expected, error.reason)
            }
            try {
                decoder.receive(byteArrayOf(0))
                fail("decoder must stay failed: $name")
            } catch (_: FrameException) {
                // expected
            }
        }
    }

    @Test
    fun binaryMessagesMatchTheVectorBytes() {
        assertTrue(InputEvent.Move(-3, 12).toFrame().encode().contentEquals(hex("010000000004fffd000c")))
        assertTrue(InputEvent.Key(PhoneKey.VOLUME_DOWN, false).toFrame().encode().contentEquals(hex("010300000003000100")))
        assertTrue(Vibration(30, 160).toFrame().encode().contentEquals(hex("030000000003001ea0")))

        val events = listOf(
            InputEvent.Move(Short.MIN_VALUE, Short.MAX_VALUE),
            InputEvent.Button(PointerButton.MIDDLE, true),
            InputEvent.Scroll(0, -20),
            InputEvent.Key(PhoneKey.VOLUME_UP, true),
        )
        for (event in events) assertEquals(event, InputEvent.from(event.toFrame()))

        assertNull(InputEvent.from(Frame(LinkChannel.INPUT, 0, byteArrayOf(-1))))
        assertNull(Vibration.from(Frame(LinkChannel.HAPTIC, 0, byteArrayOf(0))))
    }

    @Test
    fun unknownErrorCodesArePreservedAndNormalised() {
        val failure = Envelope(EnvelopeKind.Response("r", Outcome.Failure(ProtocolError("some_future_code", "New"))))
        val decoded = Envelope.decode(failure.encode()).kind as EnvelopeKind.Response
        val error = (decoded.outcome as Outcome.Failure).error
        assertEquals("some_future_code", error.code)
        assertEquals(ErrorCode.INTERNAL, error.normalizedCode)
    }
}
