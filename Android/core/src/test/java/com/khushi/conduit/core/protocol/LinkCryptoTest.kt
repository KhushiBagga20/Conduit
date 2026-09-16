package com.khushi.conduit.core.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.spec.ECPrivateKeySpec
import java.security.AlgorithmParameters
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec

/**
 * The Conduit Link cryptography, against the same vectors Conduit for Mac
 * runs. A value that differs here is a protocol break, not a detail.
 */
class LinkCryptoTest {

    private val vectors: JsonObject = Json.parseToJsonElement(
        File(System.getProperty("conduit.vectors") ?: "../../Shared/Protocol/vectors", "handshake.json").readText(),
    ).jsonObject

    private fun hex(text: String): ByteArray =
        ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    private fun string(vararg path: String): String {
        var element = vectors as kotlinx.serialization.json.JsonElement
        for (key in path) element = element.jsonObject[key]!!
        return element.jsonPrimitive.content
    }

    private fun privateKey(scalar: ByteArray) = KeyFactory.getInstance("EC").generatePrivate(
        ECPrivateKeySpec(
            BigInteger(1, scalar),
            AlgorithmParameters.getInstance("EC").run {
                init(ECGenParameterSpec(LinkCrypto.CURVE))
                getParameterSpec(ECParameterSpec::class.java)
            },
        ),
    )

    @Test
    fun agreesWithTheMacOnTheKeySchedule() {
        val shared = LinkCrypto.sharedSecret(
            privateKey(hex(string("ephemeral", "phonePrivate"))),
            LinkCrypto.publicKey(hex(string("ephemeral", "macPublic"))),
        )
        assertEquals(string("ephemeral", "sharedSecret"), hex(shared))

        val transcript = LinkCrypto.transcript(hex(string("hellos", "phone")), hex(string("hellos", "mac")))
        assertEquals(string("transcript"), hex(transcript))

        val keys = LinkCrypto.sessionKeys(shared, transcript)
        assertEquals(string("sessionKeys", "phoneToMac"), hex(keys.phoneToMac))
        assertEquals(string("sessionKeys", "macToPhone"), hex(keys.macToPhone))
    }

    @Test
    fun agreesOnWhatIsSignedAndOnThePairingCode() {
        val transcript = hex(string("transcript"))
        val phoneNonce = hex(string("pairing", "phoneNonce"))
        val macNonce = hex(string("pairing", "macNonce"))

        assertEquals(string("statements", "authPhone"),
            hex(LinkCrypto.authStatement(LinkCrypto.Role.PHONE, transcript)))
        assertEquals(string("statements", "authMac"),
            hex(LinkCrypto.authStatement(LinkCrypto.Role.MAC, transcript)))
        assertEquals(string("statements", "pairPhone"),
            hex(LinkCrypto.pairStatement(LinkCrypto.Role.PHONE, transcript, phoneNonce, macNonce)))
        assertEquals(string("statements", "pairMac"),
            hex(LinkCrypto.pairStatement(LinkCrypto.Role.MAC, transcript, phoneNonce, macNonce)))

        val phoneEphemeral = hex(string("ephemeral", "phonePublic"))
        val macEphemeral = hex(string("ephemeral", "macPublic"))
        assertEquals(string("pairing", "commitment"),
            hex(LinkCrypto.pairCommitment(macNonce, phoneEphemeral, macEphemeral)))
        assertEquals(string("pairing", "code"),
            LinkCrypto.pairingCode(phoneEphemeral, macEphemeral, phoneNonce, macNonce))
        assertEquals(string("deviceID", "id"), LinkCrypto.deviceId(hex(string("deviceID", "publicKey"))))
    }

    @Test
    fun sealsFramesTheMacCanOpenAndOpensTheMacs() {
        val key = hex(string("sessionKeys", "phoneToMac"))
        val sealer = LinkCrypto.Sealer(key)
        val opener = LinkCrypto.Opener(key)

        for (frame in vectors["sealed"]!!.jsonArray) {
            val entry = frame.jsonObject
            val channel = entry["channel"]!!.jsonPrimitive.int
            val type = entry["type"]!!.jsonPrimitive.int
            val plaintext = hex(entry["plaintext"]!!.jsonPrimitive.content)
            val expected = entry["payload"]!!.jsonPrimitive.content

            assertEquals(expected, hex(sealer.seal(plaintext, channel, type)))
            assertEquals(hex(plaintext), hex(opener.open(hex(expected), channel, type)))
        }
    }

    @Test
    fun signsWhatTheMacCanVerify() {
        val transcript = hex(string("transcript"))
        val generator = java.security.KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec(LinkCrypto.CURVE))
        val pair = generator.generateKeyPair()

        val statement = LinkCrypto.authStatement(LinkCrypto.Role.PHONE, transcript)
        val signature = LinkCrypto.sign(statement, pair.private)
        val encoded = LinkCrypto.encodePublicKey(pair.public)

        assertEquals(65, encoded.size)
        assertTrue(LinkCrypto.verify(signature, statement, encoded))
        assertTrue(!LinkCrypto.verify(signature, LinkCrypto.authStatement(LinkCrypto.Role.MAC, transcript), encoded))
    }
}
