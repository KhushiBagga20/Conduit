package com.khushi.conduit.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The vocabulary shared by every Conduit interface. Spec:
 * Shared/Protocol/README.md §6 and §8. Names are open sets — a newer peer may
 * send one this build does not know — so they travel as strings.
 */
object ActionName {
    const val SESSION_PING = "session.ping"
    const val STATE_SYNC = "state.sync"
    const val MIRRORING_REQUEST = "mirroring.request"
    const val TRACKPAD_START = "trackpad.start"
    const val TRACKPAD_STOP = "trackpad.stop"
    const val LINK_SEND = "link.send"
    const val CLIPBOARD_SET = "clipboard.set"
    const val CALL_ANSWER = "call.answer"
    const val CALL_DECLINE = "call.decline"
    const val CALL_END = "call.end"
    const val CALL_DIAL = "call.dial"
    const val CALL_MUTE = "call.mute"
    const val MAC_FIND = "mac.find"
}

object EventName {
    const val SESSION_BYE = "session.bye"
    const val DEVICE_SNAPSHOT = "device.snapshot"
    const val DEVICE_BATTERY = "device.battery"
    const val DEVICE_NETWORK = "device.network"
    const val DEVICE_LOCK = "device.lock"
    const val FEATURES_CHANGED = "features.changed"
    const val TRACKPAD_STATE = "trackpad.state"
    const val TRACKPAD_CONFIG = "trackpad.config"
    const val CALL_INCOMING = "call.incoming"
    const val CALL_STATE = "call.state"
}

enum class FeatureId(val wire: String) {
    MIRRORING("mirroring"),
    REMOTE_INPUT("remoteInput"),
    TRACKPAD("trackpad"),
    CLIPBOARD("clipboard"),
    CAMERA("camera"),
    CALLS("calls"),
    LINKS("links"),
    AUDIO("audio"),
    FILES("files"),
    NOTIFICATIONS("notifications"),
    FIND_MAC("findMac");

    companion object {
        fun fromWire(value: String): FeatureId? = entries.firstOrNull { it.wire == value }
    }
}

@Serializable
enum class Availability(val wire: String) {
    @SerialName("available") AVAILABLE("available"),
    @SerialName("active") ACTIVE("active"),
    @SerialName("requires_permission") REQUIRES_PERMISSION("requires_permission"),
    @SerialName("requires_setup") REQUIRES_SETUP("requires_setup"),
    @SerialName("disabled") DISABLED("disabled"),
    @SerialName("unsupported") UNSUPPORTED("unsupported"),
    @SerialName("planned") PLANNED("planned");

    val isUsable: Boolean get() = this == AVAILABLE || this == ACTIVE
}

object ErrorCode {
    const val INVALID_REQUEST = "invalid_request"
    const val UNSUPPORTED = "unsupported"
    const val PERMISSION_DENIED = "permission_denied"
    const val REQUIRES_SETUP = "requires_setup"
    const val DEVICE_UNAVAILABLE = "device_unavailable"
    const val PHONE_LOCKED = "phone_locked"
    const val TIMEOUT = "timeout"
    const val NETWORK_CHANGED = "network_changed"
    const val PEER_RESTARTED = "peer_restarted"
    const val DUPLICATE_REQUEST = "duplicate_request"
    const val STALE_EVENT = "stale_event"
    const val NOT_PAIRED = "not_paired"
    const val VERSION_MISMATCH = "version_mismatch"
    const val BUSY = "busy"
    const val CANCELLED = "cancelled"
    const val INTERNAL = "internal"

    val known: Set<String> = setOf(
        INVALID_REQUEST, UNSUPPORTED, PERMISSION_DENIED, REQUIRES_SETUP, DEVICE_UNAVAILABLE,
        PHONE_LOCKED, TIMEOUT, NETWORK_CHANGED, PEER_RESTARTED, DUPLICATE_REQUEST, STALE_EVENT,
        NOT_PAIRED, VERSION_MISMATCH, BUSY, CANCELLED, INTERNAL,
    )
}
