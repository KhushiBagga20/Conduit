package com.khushi.conduit.core.link

import com.khushi.conduit.core.protocol.LinkCrypto
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** The Bluetooth hotspot request against Shared/Protocol/vectors/hotspot.json, which the Mac checks too. */
class HotspotRequestTest {

    private val vectors = Json.parseToJsonElement(
        File(System.getProperty("conduit.vectors") ?: "../../Shared/Protocol/vectors", "hotspot.json").readText(),
    ).jsonObject

    private fun text(key: String) = vectors[key]!!.jsonPrimitive.content
    private fun bytes(key: String) = text(key).chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    private val timestamp = vectors["timestamp"]!!.jsonPrimitive.long
    private val paired = mapOf(text("macID") to bytes("macPublic"))

    @Test
    fun readsTheMacsRequestByteForByte() {
        assertEquals(text("macID"), LinkCrypto.deviceId(bytes("macPublic")))
        assertEquals(text("phoneID"), LinkCrypto.deviceId(bytes("phonePublic")))

        val (fields, signature) = HotspotRequest.decode(bytes("wire"))!!
        assertEquals(text("macID"), HotspotRequest.hex(fields.macId))
        assertEquals(text("phoneID"), HotspotRequest.hex(fields.phoneId))
        assertEquals(timestamp, fields.timestamp)
        assertEquals(text("statement"), HotspotRequest.hex(HotspotRequest.statement(fields)))
        assertEquals(text("signature"), HotspotRequest.hex(signature))
    }

    @Test
    fun acceptsAFreshRequestFromThePairedMacOnce() {
        val gate = HotspotRequestGate(now = { timestamp + 30_000 })
        assertEquals(text("macID"), gate.check(bytes("wire"), text("phoneID"), paired))
        // The same request again is a replay.
        assertNull(gate.check(bytes("wire"), text("phoneID"), paired))
    }

    @Test
    fun ignoresEverythingElse() {
        val wire = bytes("wire")
        fun fresh() = HotspotRequestGate(now = { timestamp })

        assertNull("another phone", fresh().check(wire, "00".repeat(16), paired))
        assertNull("an unpaired Mac", fresh().check(wire, text("phoneID"), emptyMap()))
        assertNull("too old", HotspotRequestGate(now = { timestamp + 3 * 60_000 }).check(wire, text("phoneID"), paired))
        assertNull("from the future", HotspotRequestGate(now = { timestamp - 3 * 60_000 }).check(wire, text("phoneID"), paired))

        val tampered = wire.copyOf().also { it[45] = (it[45].toInt() xor 1).toByte() }
        assertNull("a changed nonce", fresh().check(tampered, text("phoneID"), paired))
        assertNull("not a request", fresh().check(byteArrayOf(2) + wire.copyOfRange(1, wire.size), text("phoneID"), paired))
    }
}
