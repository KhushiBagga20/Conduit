package com.khushi.conduit.core.protocol

import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The cryptography of Conduit Link v1, exactly as Shared/Protocol/README.md §5
 * defines it. Every constant string and byte order here is part of the wire
 * protocol: Conduit for Mac computes the same values, and
 * Shared/Protocol/vectors/handshake.json pins them down for both.
 */
object LinkCrypto {

    const val CURVE = "secp256r1"
    private const val COORDINATE_BYTES = 32
    private const val TAG_BITS = 128

    enum class Role(val wire: String) { PHONE("phone"), MAC("mac") }

    class SessionKeys(val phoneToMac: ByteArray, val macToPhone: ByteArray)

    // Keys

    private val curve: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").run {
            init(ECGenParameterSpec(CURVE))
            getParameterSpec(ECParameterSpec::class.java)
        }
    }

    /** A P-256 public key from its 65-byte uncompressed X9.63 encoding. */
    fun publicKey(x963: ByteArray): PublicKey {
        require(x963.size == 1 + 2 * COORDINATE_BYTES && x963[0] == 0x04.toByte()) { "not an uncompressed P-256 point" }
        val x = BigInteger(1, x963.copyOfRange(1, 1 + COORDINATE_BYTES))
        val y = BigInteger(1, x963.copyOfRange(1 + COORDINATE_BYTES, x963.size))
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), curve))
    }

    /** The 65-byte uncompressed X9.63 encoding the protocol sends. */
    fun encodePublicKey(key: PublicKey): ByteArray {
        val point = (key as ECPublicKey).w
        return byteArrayOf(0x04) + fixed(point.affineX) + fixed(point.affineY)
    }

    private fun fixed(value: BigInteger): ByteArray {
        val bytes = value.toByteArray()
        return when {
            bytes.size == COORDINATE_BYTES -> bytes
            bytes.size > COORDINATE_BYTES -> bytes.copyOfRange(bytes.size - COORDINATE_BYTES, bytes.size)
            else -> ByteArray(COORDINATE_BYTES - bytes.size) + bytes
        }
    }

    /** The first 16 bytes of SHA-256 over the public key, in lowercase hex. */
    fun deviceId(publicKey: ByteArray): String =
        sha256(publicKey).copyOfRange(0, 16).joinToString("") { "%02x".format(it) }

    // Key schedule

    /** ECDH over P-256: the x-coordinate of the shared point, 32 bytes. */
    fun sharedSecret(privateKey: PrivateKey, publicKey: PublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(privateKey)
            doPhase(publicKey, true)
            generateSecret()
        }

    /** SHA-256 over both hello payloads, in the order they were sent. */
    fun transcript(phoneHello: ByteArray, macHello: ByteArray): ByteArray = sha256(phoneHello + macHello)

    fun sessionKeys(sharedSecret: ByteArray, transcript: ByteArray) = SessionKeys(
        phoneToMac = hkdf(sharedSecret, transcript, "conduit v1 phone->mac"),
        macToPhone = hkdf(sharedSecret, transcript, "conduit v1 mac->phone"),
    )

    /** HKDF-SHA256 (RFC 5869), one 32-byte block. */
    private fun hkdf(secret: ByteArray, salt: ByteArray, info: String): ByteArray {
        val pseudorandomKey = hmac(key = salt, data = secret)
        return hmac(key = pseudorandomKey, data = info.toByteArray() + byteArrayOf(0x01))
    }

    // Signed statements

    fun authStatement(role: Role, transcript: ByteArray): ByteArray =
        "conduit-auth-v1".toByteArray() + role.wire.toByteArray() + transcript

    fun pairStatement(role: Role, transcript: ByteArray, phoneNonce: ByteArray, macNonce: ByteArray): ByteArray =
        "conduit-pair-v1".toByteArray() + role.wire.toByteArray() + transcript + phoneNonce + macNonce

    /** DER-encoded ECDSA-SHA256, the same form CryptoKit produces. */
    fun sign(statement: ByteArray, privateKey: PrivateKey): ByteArray =
        Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey)
            update(statement)
            sign()
        }

    fun verify(signature: ByteArray, statement: ByteArray, publicKey: ByteArray): Boolean = try {
        Signature.getInstance("SHA256withECDSA").run {
            initVerify(publicKey(publicKey))
            update(statement)
            verify(signature)
        }
    } catch (_: Exception) {
        false
    }

    // Pairing

    /** HMAC-SHA256(key: the Mac's nonce, message: ephC ‖ ephS). */
    fun pairCommitment(macNonce: ByteArray, phoneEphemeral: ByteArray, macEphemeral: ByteArray): ByteArray =
        hmac(key = macNonce, data = phoneEphemeral + macEphemeral)

    /** The six digits shown on both devices. */
    fun pairingCode(
        phoneEphemeral: ByteArray,
        macEphemeral: ByteArray,
        phoneNonce: ByteArray,
        macNonce: ByteArray,
    ): String {
        val digest = sha256("conduit-sas-v1".toByteArray() + phoneEphemeral + macEphemeral + phoneNonce + macNonce)
        val value = ByteBuffer.wrap(digest, 0, 4).int.toLong() and 0xFFFF_FFFFL
        return "%06d".format(value % 1_000_000)
    }

    // Sealed frames

    /**
     * AES-256-GCM with one key and one counter per direction. The nonce is
     * four zero bytes then the counter, big-endian; the frame's channel and
     * type bytes are the associated data, so a frame cannot be replayed on
     * another channel.
     */
    class Sealer(key: ByteArray) {
        private val key = SecretKeySpec(key, "AES")
        private var counter = 0L

        @Synchronized
        fun seal(plaintext: ByteArray, channel: Int, type: Int): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonce(counter)))
            counter += 1
            cipher.updateAAD(byteArrayOf(channel.toByte(), type.toByte()))
            return cipher.doFinal(plaintext)
        }
    }

    class Opener(key: ByteArray) {
        private val key = SecretKeySpec(key, "AES")
        private var counter = 0L

        /** Throws when the frame does not open; the connection must then close. */
        @Synchronized
        fun open(payload: ByteArray, channel: Int, type: Int): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, nonce(counter)))
            cipher.updateAAD(byteArrayOf(channel.toByte(), type.toByte()))
            val plaintext = cipher.doFinal(payload)
            counter += 1
            return plaintext
        }
    }

    private fun nonce(counter: Long): ByteArray = ByteBuffer.allocate(12).putInt(0).putLong(counter).array()

    // Primitives

    private fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(key, "HmacSHA256"))
            doFinal(data)
        }
}
