package com.khushi.conduit.link

import android.util.Log
import com.khushi.conduit.core.link.LinkSigner
import com.khushi.conduit.core.link.PhoneHandshake
import com.khushi.conduit.core.protocol.ControlType
import com.khushi.conduit.core.protocol.DeviceInfo
import com.khushi.conduit.core.protocol.Envelope
import com.khushi.conduit.core.protocol.ErrorCode
import com.khushi.conduit.core.protocol.Frame
import com.khushi.conduit.core.protocol.FrameDecoder
import com.khushi.conduit.core.protocol.HandshakeIntent
import com.khushi.conduit.core.protocol.HandshakeMessage
import com.khushi.conduit.core.protocol.LinkChannel
import com.khushi.conduit.core.protocol.LinkCrypto
import com.khushi.conduit.core.protocol.LinkSessionInfo
import com.khushi.conduit.core.protocol.ProtocolError
import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * One connection from this phone to a Mac: the socket, the frames, the
 * handshake driven to ready, and sealed envelopes after it.
 *
 * [run] blocks its thread until the connection ends, so callers give it one.
 * The two hellos are plaintext; everything after is sealed, and a frame that
 * does not open ends the connection rather than being guessed at.
 */
class LinkConnection(
    signer: LinkSigner,
    device: DeviceInfo,
    intent: HandshakeIntent,
    expectedMacKey: ByteArray?,
    private val listener: Listener,
) {

    interface Listener {
        fun onPairingCode(code: String, mac: DeviceInfo) {}
        fun onReady(connection: LinkConnection, mac: DeviceInfo, macKey: ByteArray, session: LinkSessionInfo) {}
        fun onEnvelope(connection: LinkConnection, envelope: Envelope) {}
        fun onClosed(error: ProtocolError?) {}
    }

    private val handshake = PhoneHandshake(signer, device, intent, expectedMacKey)
    private val socket = Socket()
    private val decoder = FrameDecoder()
    private var output: OutputStream? = null
    private var sealer: LinkCrypto.Sealer? = null
    private var opener: LinkCrypto.Opener? = null
    @Volatile private var ready = false
    @Volatile private var closed = false
    private var closeError: ProtocolError? = null

    /** Connect and serve until the connection ends. */
    fun run(host: String, port: Int, connectTimeoutMs: Int = 4_000) {
        try {
            socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
            socket.tcpNoDelay = true
            // The handshake has a minute; after it, silence longer than three
            // missed heartbeats means the Mac has gone.
            socket.soTimeout = 60_000
            output = socket.getOutputStream()
            perform(handshake.start())

            val input = socket.getInputStream()
            val buffer = ByteArray(64 * 1024)
            while (!closed) {
                val count = input.read(buffer)
                if (count < 0) break
                for (frame in decoder.receive(buffer.copyOf(count))) {
                    if (closed) break
                    handle(frame)
                }
            }
        } catch (error: IOException) {
            if (!closed) closeError = ProtocolError(ErrorCode.DEVICE_UNAVAILABLE, "The Mac could not be reached.")
            Log.i(TAG, "connection ended: ${error.javaClass.simpleName}")
        } catch (error: Exception) {
            if (!closed) closeError = ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac sent something Conduit could not read.")
            Log.w(TAG, "connection failed", error)
        } finally {
            finish()
        }
    }

    fun confirmPairing() = perform(handshake.confirmPairing())

    fun rejectPairing() = perform(handshake.rejectPairing())

    fun send(envelope: Envelope) {
        if (!ready) return
        send(envelope.encode().encodeToByteArray(), ControlType.ENVELOPE, sealed = true)
    }

    /** Heartbeat interval agreed at ready; reads give up after three missed. */
    fun useHeartbeat(seconds: Int) {
        runCatching { socket.soTimeout = seconds * 3_000 }
    }

    fun close(error: ProtocolError? = null) {
        if (closed) return
        closeError = closeError ?: error
        closed = true
        runCatching { socket.close() }
    }

    private fun handle(frame: Frame) {
        val payload = opener?.let {
            try {
                it.open(frame.payload, frame.channel.value, frame.type)
            } catch (_: Exception) {
                close(ProtocolError(ErrorCode.INTERNAL, "A message from the Mac could not be opened."))
                return
            }
        } ?: frame.payload

        when {
            frame.channel == LinkChannel.CONTROL && frame.type == ControlType.HANDSHAKE -> {
                if (ready) return close(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac tried to hand shake twice."))
                val message = runCatching { HandshakeMessage.decode(payload) }.getOrNull()
                    ?: return close(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac sent an unreadable handshake."))
                perform(handshake.receive(message, payload))
            }
            frame.channel == LinkChannel.CONTROL && frame.type == ControlType.ENVELOPE -> {
                if (!ready) return close(ProtocolError(ErrorCode.NOT_PAIRED, "The Mac sent messages before the handshake finished."))
                val envelope = runCatching { Envelope.decode(payload.decodeToString()) }.getOrNull()
                    ?: return close(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac sent an unreadable message."))
                listener.onEnvelope(this, envelope)
            }
            // Other channels arrive with their features.
            else -> Unit
        }
    }

    private fun perform(actions: List<PhoneHandshake.Action>) {
        for (action in actions) {
            when (action) {
                is PhoneHandshake.Action.Send -> send(action.payload, ControlType.HANDSHAKE, action.sealed)
                is PhoneHandshake.Action.KeysEstablished -> {
                    // The phone seals with its own key and opens with the Mac's.
                    sealer = LinkCrypto.Sealer(action.keys.phoneToMac)
                    opener = LinkCrypto.Opener(action.keys.macToPhone)
                }
                is PhoneHandshake.Action.ConfirmPairing -> listener.onPairingCode(action.code, action.mac)
                is PhoneHandshake.Action.Ready -> {
                    ready = true
                    listener.onReady(this, action.mac, action.macIdentityKey, action.session)
                }
                is PhoneHandshake.Action.Fail -> close(action.error)
            }
        }
    }

    private fun send(payload: ByteArray, type: Int, sealed: Boolean) {
        if (closed) return
        val body = if (sealed) {
            sealer?.seal(payload, LinkChannel.CONTROL.value, type)
                ?: return close(ProtocolError(ErrorCode.INTERNAL, "Conduit tried to seal a message before the keys existed."))
        } else {
            payload
        }
        try {
            synchronized(socket) { output?.run { write(Frame(LinkChannel.CONTROL, type, body).encode()); flush() } }
        } catch (_: IOException) {
            close(ProtocolError(ErrorCode.DEVICE_UNAVAILABLE, "The Mac stopped answering."))
        }
    }

    private fun finish() {
        closed = true
        runCatching { socket.close() }
        listener.onClosed(closeError)
    }

    private companion object {
        const val TAG = "ConduitLink"
    }
}
