package com.khushi.conduit.link

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/**
 * Conduit Link as the interface sees it. [LinkService] owns the connection
 * and writes here; screens read it.
 */
object LinkHub {

    /** A Mac this phone can see, by Bonjour or because the Mac said where it is over adb. */
    data class FoundMac(val id: String?, val name: String, val hosts: List<String>, val port: Int)

    data class PairingPrompt(val code: String, val macName: String)

    sealed interface Status {
        data object Off : Status
        data object Looking : Status
        data class Connecting(val macName: String) : Status
        data class Connected(val macName: String) : Status
        data class Failed(val message: String) : Status
    }

    data class State(
        val linked: List<LinkedMac> = emptyList(),
        val connectedId: String? = null,
        val status: Status = Status.Off,
        /** True while the person is adding a Mac. */
        val adding: Boolean = false,
        val found: List<FoundMac> = emptyList(),
        val pairing: PairingPrompt? = null,
        /** A paired Mac can ask for the hotspot over Bluetooth right now. */
        val hotspotRequestsReady: Boolean = false,
    )

    private val mutable = MutableStateFlow(State())
    val state: StateFlow<State> = mutable

    internal fun update(change: (State) -> State) = mutable.update(change)
}
