package com.khushi.conduit.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Payload objects shared by several messages. Spec: Shared/Protocol/README.md §6. */
@Serializable
enum class Platform {
    @SerialName("android") ANDROID,
    @SerialName("macos") MACOS,
}

@Serializable
data class DeviceInfo(
    val id: String,
    val name: String,
    val model: String? = null,
    val manufacturer: String? = null,
    val platform: Platform,
    val osVersion: String? = null,
    val appVersion: String? = null,
)

@Serializable
data class BatteryStatus(val level: Int, val charging: Boolean)

@Serializable
enum class NetworkType {
    @SerialName("wifi") WIFI,
    @SerialName("cellular") CELLULAR,
    @SerialName("ethernet") ETHERNET,
    @SerialName("none") NONE,
}

@Serializable
data class NetworkStatus(val type: NetworkType)

/**
 * One notification showing on this phone — Shared/Protocol/README.md §6.
 *
 * It carries only what the Mac shows. A notification the app marks private
 * travels [redacted], with no title or text at all, so there is nothing in
 * it to leak.
 */
@Serializable
data class PhoneNotification(
    /** This phone's own key for it, used to dismiss or open it again. */
    val key: String,
    val appID: String,
    val appName: String,
    val title: String? = null,
    val text: String? = null,
    /** Milliseconds since the Unix epoch. */
    val postedAt: Long,
    val clearable: Boolean = true,
    val redacted: Boolean = false,
)

@Serializable
data class DeviceSnapshot(
    val device: DeviceInfo,
    val battery: BatteryStatus? = null,
    val network: NetworkStatus? = null,
    val locked: Boolean? = null,
    /** Keyed by feature wire name; unknown features are kept, not dropped. */
    val features: Map<String, Availability> = emptyMap(),
)
