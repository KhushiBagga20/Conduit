package com.khushi.conduit.core.protocol

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * The JSON message carried on channel 0 after the handshake: a command, a
 * response or an event. Spec: Shared/Protocol/README.md §3.
 *
 * Decoding enforces every field rule in the spec, so a malformed envelope is
 * rejected at the edge instead of reaching feature code half-formed. The Mac
 * counterpart is ConduitProtocol/Envelope.swift; both run the same vectors.
 */
object ProtocolVersion {
    const val CURRENT = 1
    const val MINIMUM = 1
}

class ProtocolException(message: String) : Exception(message)

data class ProtocolError(val code: String, val message: String) {
    /** Spec §8: a code this build does not know is handled as `internal`. */
    val normalizedCode: String get() = if (code in ErrorCode.known) code else ErrorCode.INTERNAL
}

sealed interface Outcome {
    data object Success : Outcome
    data class Failure(val error: ProtocolError) : Outcome
}

sealed interface EnvelopeKind {
    data class Command(val requestId: String, val action: String) : EnvelopeKind
    data class Response(val requestId: String, val outcome: Outcome) : EnvelopeKind
    data class Event(val name: String, val epoch: String, val seq: Long, val timestamp: Long?) : EnvelopeKind
}

data class Envelope(
    val kind: EnvelopeKind,
    val payload: JsonObject? = null,
    val version: Int = ProtocolVersion.CURRENT,
) {

    fun toJson(): JsonObject = buildJsonObject {
        put("v", version)
        when (kind) {
            is EnvelopeKind.Command -> {
                put("type", "command")
                put("requestID", kind.requestId)
                put("action", kind.action)
            }
            is EnvelopeKind.Response -> {
                put("type", "response")
                put("requestID", kind.requestId)
                when (val outcome = kind.outcome) {
                    Outcome.Success -> put("status", "success")
                    is Outcome.Failure -> {
                        put("status", "failure")
                        put("error", buildJsonObject {
                            put("code", outcome.error.code)
                            put("message", outcome.error.message)
                        })
                    }
                }
            }
            is EnvelopeKind.Event -> {
                put("type", "event")
                put("event", kind.name)
                put("epoch", kind.epoch)
                put("seq", kind.seq)
                kind.timestamp?.let { put("timestamp", it) }
            }
        }
        payload?.let { put("payload", it) }
    }

    fun encode(): String = toJson().toString()

    companion object {

        fun decode(text: String): Envelope = fromJson(ProtocolJson.parse(text))

        fun fromJson(element: JsonElement): Envelope {
            val json = element as? JsonObject ?: throw ProtocolException("envelope must be a JSON object")

            val version = json.integer("v")?.toInt() ?: throw ProtocolException("v must be an integer")

            val payload = when (val raw = json["payload"]) {
                null -> null
                is JsonObject -> raw
                else -> throw ProtocolException("payload must be a JSON object")
            }

            val kind = when (json.string("type")) {
                "command" -> EnvelopeKind.Command(
                    requestId = json.requireString("requestID"),
                    action = json.requireString("action"),
                )
                "response" -> {
                    val requestId = json.requireString("requestID")
                    val outcome = when (json.string("status")) {
                        "success" -> Outcome.Success
                        "failure" -> {
                            val error = json["error"] as? JsonObject
                                ?: throw ProtocolException("failure needs an error object")
                            Outcome.Failure(ProtocolError(error.requireString("code"), error.requireString("message")))
                        }
                        else -> throw ProtocolException("status must be success or failure")
                    }
                    EnvelopeKind.Response(requestId, outcome)
                }
                "event" -> {
                    val seq = json.integer("seq") ?: throw ProtocolException("seq must be an integer")
                    if (seq < 1) throw ProtocolException("seq starts at 1")
                    EnvelopeKind.Event(
                        name = json.requireString("event"),
                        epoch = json.requireString("epoch"),
                        seq = seq,
                        timestamp = if (json.containsKey("timestamp")) {
                            json.integer("timestamp") ?: throw ProtocolException("timestamp must be an integer")
                        } else null,
                    )
                }
                else -> throw ProtocolException("type must be command, response or event")
            }

            return Envelope(kind = kind, payload = payload, version = version)
        }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

        private fun JsonObject.requireString(key: String): String =
            string(key) ?: throw ProtocolException("$key must be a string")

        /** An integer JSON number — not a string, not a fraction. */
        private fun JsonObject.integer(key: String): Long? =
            (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
    }
}

internal object ProtocolJson {
    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }

    fun parse(text: String): JsonElement = json.parseToJsonElement(text)
}
