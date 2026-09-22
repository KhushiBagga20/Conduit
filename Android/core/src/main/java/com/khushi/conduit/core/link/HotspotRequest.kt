package com.khushi.conduit.core.link

import com.khushi.conduit.core.protocol.LinkCrypto
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * A Mac asking, over Bluetooth LE, for this phone's hotspot —
 * Shared/Protocol/README.md §8a. The Mac signs it with its Conduit Link
 * identity key and addresses it to one phone.
 */
object HotspotRequest {

    const val SERVICE_UUID = "9D99F667-22A5-4207-B9F0-CF2A1F80D81B"
    const val CHARACTERISTIC_UUID = "A9FE1931-A845-4B54-811D-9095A568370A"
    private const val VERSION: Byte = 1
    private const val HEADER = 1 + 16 + 16 + 8 + 16

    class Fields(val macId: ByteArray, val phoneId: ByteArray, val timestamp: Long, val nonce: ByteArray)

    /** `"conduit-hotspot-v1" ‖ macID ‖ phoneID ‖ timestamp ‖ nonce` */
    fun statement(fields: Fields): ByteArray =
        "conduit-hotspot-v1".toByteArray() + fields.macId + fields.phoneId +
            ByteBuffer.allocate(8).putLong(fields.timestamp).array() + fields.nonce

    /** The fields and the signature, or null when the bytes are not a request. */
    fun decode(bytes: ByteArray): Pair<Fields, ByteArray>? {
        if (bytes.size <= HEADER || bytes[0] != VERSION) return null
        val fields = Fields(
            macId = bytes.copyOfRange(1, 17),
            phoneId = bytes.copyOfRange(17, 33),
            timestamp = ByteBuffer.wrap(bytes, 33, 8).long,
            nonce = bytes.copyOfRange(41, 57),
        )
        return fields to bytes.copyOfRange(HEADER, bytes.size)
    }

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
}

/**
 * Decides whether a hotspot request deserves a notification. It must come
 * from a paired Mac, be addressed to this phone, carry that Mac's signature,
 * and be fresh: within two minutes of this phone's clock, with a nonce not
 * seen in the last five. Anything else is dropped without an answer.
 */
class HotspotRequestGate(private val now: () -> Long = System::currentTimeMillis) {

    private val seen = LinkedHashMap<String, Long>()

    /** The device ID of the Mac that asked, or null to ignore the request. */
    @Synchronized
    fun check(request: ByteArray, phoneId: String, pairedMacKeys: Map<String, ByteArray>): String? {
        val (fields, signature) = HotspotRequest.decode(request) ?: return null
        val macId = HotspotRequest.hex(fields.macId)
        val macKey = pairedMacKeys[macId] ?: return null
        if (HotspotRequest.hex(fields.phoneId) != phoneId) return null

        val time = now()
        if (abs(time - fields.timestamp) > FRESH_MILLIS) return null
        seen.entries.removeAll { time - it.value > NONCE_MEMORY_MILLIS }
        val nonce = HotspotRequest.hex(fields.nonce)
        if (nonce in seen) return null

        if (!LinkCrypto.verify(signature, HotspotRequest.statement(fields), macKey)) return null
        seen[nonce] = time
        return macId
    }

    private companion object {
        const val FRESH_MILLIS = 2 * 60_000L
        const val NONCE_MEMORY_MILLIS = 5 * 60_000L
    }
}
