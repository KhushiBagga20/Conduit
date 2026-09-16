package com.khushi.conduit.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * The handshake messages of Conduit Link v1 — Shared/Protocol/README.md §5.
 * They travel as `control/handshake` frames: JSON objects, plaintext for the
 * two hellos and sealed from `auth` onwards.
 *
 * A message is hashed into the transcript exactly as it went on the wire, so
 * the bytes from [encode] are kept and never re-encoded before hashing.
 */
@Serializable
enum class HandshakeStep {
    @SerialName("hello") HELLO,
    @SerialName("auth") AUTH,
    @SerialName("ready") READY,
    @SerialName("error") ERROR,
    @SerialName("pair.nonce") PAIR_NONCE,
    @SerialName("pair.reveal") PAIR_REVEAL,
    @SerialName("pair.confirm") PAIR_CONFIRM,
    @SerialName("pair.reject") PAIR_REJECT,
}

/** What the phone is asking for. */
@Serializable
enum class HandshakeIntent {
    @SerialName("connect") CONNECT,
    @SerialName("pair") PAIR,
}

/** What the Mac answered: prove an identity it already trusts, or pair. */
@Serializable
enum class HandshakeMode {
    @SerialName("authenticate") AUTHENTICATE,
    @SerialName("pair") PAIR,
}

@Serializable
data class LinkSessionInfo(val epoch: String, val heartbeatSeconds: Int)

@Serializable
data class HandshakeError(val code: String, val message: String)

@Serializable
data class HandshakeMessage(
    val type: String = TYPE,
    val step: HandshakeStep,
    val versions: List<Int>? = null,
    val device: DeviceInfo? = null,
    /** Base64, X9.63 uncompressed point. */
    val identityKey: String? = null,
    val ephemeralKey: String? = null,
    val intent: HandshakeIntent? = null,
    val version: Int? = null,
    val mode: HandshakeMode? = null,
    val commitment: String? = null,
    val nonce: String? = null,
    /** Base64 DER ECDSA signature: `auth` and `pair.confirm`. */
    val signature: String? = null,
    val session: LinkSessionInfo? = null,
    val error: HandshakeError? = null,
) {
    fun encode(): ByteArray = json.encodeToString(serializer(), this).encodeToByteArray()

    companion object {
        const val TYPE = "handshake"

        private val json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            encodeDefaults = true
        }

        fun decode(bytes: ByteArray): HandshakeMessage {
            val message = json.decodeFromString(serializer(), bytes.decodeToString())
            if (message.type != TYPE) throw ProtocolException("Not a handshake message.")
            return message
        }
    }
}
