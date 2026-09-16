package com.khushi.conduit.core.link

import com.khushi.conduit.core.protocol.DeviceInfo
import com.khushi.conduit.core.protocol.ErrorCode
import com.khushi.conduit.core.protocol.HandshakeError
import com.khushi.conduit.core.protocol.HandshakeIntent
import com.khushi.conduit.core.protocol.HandshakeMessage
import com.khushi.conduit.core.protocol.HandshakeMode
import com.khushi.conduit.core.protocol.HandshakeStep
import com.khushi.conduit.core.protocol.LinkCrypto
import com.khushi.conduit.core.protocol.LinkSessionInfo
import com.khushi.conduit.core.protocol.ProtocolError
import com.khushi.conduit.core.protocol.ProtocolVersion
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.util.Base64

/** This phone's long-term identity: the key never leaves the Android Keystore. */
interface LinkSigner {
    /** X9.63 uncompressed point. */
    val publicKey: ByteArray
    fun sign(statement: ByteArray): ByteArray
}

/**
 * The phone's side of the Conduit Link handshake — Shared/Protocol/README.md
 * §5 — as a state machine with no sockets in it, the mirror of the Mac's
 * LinkHandshake.
 *
 * It says hello, derives the session keys, proves this phone's identity and
 * checks the Mac's, and where the two are pairing, checks the Mac's
 * commitment before it shows the six digits. Nothing is trusted until a
 * signature over the transcript verifies.
 */
class PhoneHandshake(
    private val signer: LinkSigner,
    private val device: DeviceInfo,
    private val intent: HandshakeIntent,
    /** The Mac's identity key when reconnecting to a Mac this phone paired with. */
    private val expectedMacKey: ByteArray? = null,
    private val random: SecureRandom = SecureRandom(),
) {

    sealed interface Action {
        /** Exactly the bytes to put on the wire. */
        class Send(val step: HandshakeStep, val payload: ByteArray, val sealed: Boolean) : Action

        /** From here on everything sent is sealed. */
        class KeysEstablished(val keys: LinkCrypto.SessionKeys) : Action

        /** Show these six digits and ask the person to compare them with the Mac. */
        data class ConfirmPairing(val code: String, val mac: DeviceInfo) : Action

        class Ready(val mac: DeviceInfo, val macIdentityKey: ByteArray, val session: LinkSessionInfo) : Action

        data class Fail(val error: ProtocolError) : Action
    }

    private enum class Step { NEW, AWAITING_HELLO, AUTHENTICATING, AWAITING_REVEAL, PAIRING, DONE, FAILED }

    private var step = Step.NEW
    private val ephemeral = KeyPairGenerator.getInstance("EC").run {
        initialize(ECGenParameterSpec(LinkCrypto.CURVE), random)
        generateKeyPair()
    }
    private val phoneEphemeral = LinkCrypto.encodePublicKey(ephemeral.public)
    private val phoneNonce = ByteArray(32).also(random::nextBytes)

    private var ourHello = ByteArray(0)
    private var transcript = ByteArray(0)
    private var mode: HandshakeMode? = null
    private var mac: DeviceInfo? = null
    private var macIdentity = ByteArray(0)
    private var macEphemeral = ByteArray(0)
    private var commitment = ByteArray(0)
    private var macNonce = ByteArray(0)
    private var macAuthenticated = false
    private var macConfirmed = false
    private var userConfirmed = false

    fun start(): List<Action> {
        check(step == Step.NEW)
        ourHello = HandshakeMessage(
            step = HandshakeStep.HELLO,
            versions = listOf(ProtocolVersion.CURRENT),
            device = device,
            identityKey = base64(signer.publicKey),
            ephemeralKey = base64(phoneEphemeral),
            intent = intent,
        ).encode()
        step = Step.AWAITING_HELLO
        return listOf(Action.Send(HandshakeStep.HELLO, ourHello, sealed = false))
    }

    /** [raw] is the payload exactly as it arrived. */
    fun receive(message: HandshakeMessage, raw: ByteArray): List<Action> = when {
        message.step == HandshakeStep.ERROR ->
            fail(message.error?.let { ProtocolError(it.code, it.message) }
                ?: ProtocolError(ErrorCode.INTERNAL, "The Mac reported an error."))
        message.step == HandshakeStep.PAIR_REJECT ->
            fail(ProtocolError(ErrorCode.CANCELLED, "Pairing was refused on the Mac."))
        step == Step.AWAITING_HELLO && message.step == HandshakeStep.HELLO -> hello(message, raw)
        step == Step.AUTHENTICATING && message.step == HandshakeStep.AUTH -> macAuth(message)
        step == Step.AUTHENTICATING && message.step == HandshakeStep.READY -> readyAfterAuth(message)
        step == Step.AWAITING_REVEAL && message.step == HandshakeStep.PAIR_REVEAL -> reveal(message)
        step == Step.PAIRING && message.step == HandshakeStep.PAIR_CONFIRM -> macConfirm(message)
        step == Step.PAIRING && message.step == HandshakeStep.READY -> readyAfterPairing(message)
        else -> fail(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac sent an unexpected handshake step."))
    }

    /** The person compared the digits on this phone and said yes. */
    fun confirmPairing(): List<Action> {
        if (step != Step.PAIRING || userConfirmed) return emptyList()
        userConfirmed = true
        val statement = LinkCrypto.pairStatement(LinkCrypto.Role.PHONE, transcript, phoneNonce, macNonce)
        val confirm = HandshakeMessage(step = HandshakeStep.PAIR_CONFIRM, signature = base64(signer.sign(statement)))
        return listOf(Action.Send(HandshakeStep.PAIR_CONFIRM, confirm.encode(), sealed = true))
    }

    fun rejectPairing(): List<Action> {
        if (step != Step.PAIRING) return emptyList()
        step = Step.FAILED
        return listOf(
            Action.Send(HandshakeStep.PAIR_REJECT, HandshakeMessage(step = HandshakeStep.PAIR_REJECT).encode(), sealed = true),
            Action.Fail(ProtocolError(ErrorCode.CANCELLED, "Pairing was refused on this phone.")),
        )
    }

    // Steps

    private fun hello(message: HandshakeMessage, raw: ByteArray): List<Action> {
        val macDevice = message.device
        val identity = message.identityKey?.let(::unbase64)
        val ephemeralKey = message.ephemeralKey?.let(::unbase64)
        val agreedMode = message.mode
        if (message.version != ProtocolVersion.CURRENT || macDevice == null || identity == null ||
            ephemeralKey == null || agreedMode == null
        ) {
            return fail(ProtocolError(ErrorCode.VERSION_MISMATCH, "The Mac speaks a Conduit Link version this phone does not."))
        }
        if (LinkCrypto.deviceId(identity) != macDevice.id) {
            return fail(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac's device ID does not match its key."))
        }
        if (expectedMacKey != null && !expectedMacKey.contentEquals(identity)) {
            return fail(ProtocolError(ErrorCode.NOT_PAIRED, "This is not the Mac this phone paired with."))
        }
        // A Mac that wants to pair when this phone only asked to connect has
        // forgotten it. Pairing again is the person's choice, made on purpose.
        if (agreedMode == HandshakeMode.PAIR && intent != HandshakeIntent.PAIR) {
            return fail(ProtocolError(ErrorCode.NOT_PAIRED, "The Mac no longer knows this phone. Add it again."))
        }

        val shared = try {
            LinkCrypto.sharedSecret(ephemeral.private, LinkCrypto.publicKey(ephemeralKey))
        } catch (_: Exception) {
            return fail(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac sent an unusable key."))
        }

        mac = macDevice
        mode = agreedMode
        macIdentity = identity
        macEphemeral = ephemeralKey
        transcript = LinkCrypto.transcript(ourHello, raw)
        val keys = LinkCrypto.sessionKeys(shared, transcript)
        val actions = mutableListOf<Action>(Action.KeysEstablished(keys))

        if (agreedMode == HandshakeMode.AUTHENTICATE) {
            val statement = LinkCrypto.authStatement(LinkCrypto.Role.PHONE, transcript)
            val auth = HandshakeMessage(step = HandshakeStep.AUTH, signature = base64(signer.sign(statement)))
            actions += Action.Send(HandshakeStep.AUTH, auth.encode(), sealed = true)
            step = Step.AUTHENTICATING
        } else {
            commitment = message.commitment?.let(::unbase64)
                ?: return fail(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac did not commit to its pairing nonce."))
            val nonce = HandshakeMessage(step = HandshakeStep.PAIR_NONCE, nonce = base64(phoneNonce))
            actions += Action.Send(HandshakeStep.PAIR_NONCE, nonce.encode(), sealed = true)
            step = Step.AWAITING_REVEAL
        }
        return actions
    }

    private fun macAuth(message: HandshakeMessage): List<Action> {
        val signature = message.signature?.let(::unbase64)
        val statement = LinkCrypto.authStatement(LinkCrypto.Role.MAC, transcript)
        if (signature == null || !LinkCrypto.verify(signature, statement, macIdentity)) {
            return fail(ProtocolError(ErrorCode.NOT_PAIRED, "The Mac could not prove its identity."))
        }
        macAuthenticated = true
        return emptyList()
    }

    private fun readyAfterAuth(message: HandshakeMessage): List<Action> {
        if (!macAuthenticated) return fail(ProtocolError(ErrorCode.NOT_PAIRED, "The Mac said ready before proving itself."))
        return ready(message)
    }

    private fun reveal(message: HandshakeMessage): List<Action> {
        val revealed = message.nonce?.let(::unbase64)
        if (revealed == null || revealed.size != 32 ||
            !LinkCrypto.pairCommitment(revealed, phoneEphemeral, macEphemeral).contentEquals(commitment)
        ) {
            // The Mac's nonce does not match what it committed to before it
            // saw ours: someone may be choosing values to force the code.
            return fail(ProtocolError(ErrorCode.NOT_PAIRED, "The Mac's pairing did not check out."))
        }
        macNonce = revealed
        step = Step.PAIRING
        val code = LinkCrypto.pairingCode(phoneEphemeral, macEphemeral, phoneNonce, macNonce)
        return listOf(Action.ConfirmPairing(code, mac!!))
    }

    private fun macConfirm(message: HandshakeMessage): List<Action> {
        val signature = message.signature?.let(::unbase64)
        val statement = LinkCrypto.pairStatement(LinkCrypto.Role.MAC, transcript, phoneNonce, macNonce)
        if (signature == null || !LinkCrypto.verify(signature, statement, macIdentity)) {
            return fail(ProtocolError(ErrorCode.NOT_PAIRED, "The Mac's pairing signature did not check out."))
        }
        macConfirmed = true
        return emptyList()
    }

    private fun readyAfterPairing(message: HandshakeMessage): List<Action> {
        if (!userConfirmed || !macConfirmed) {
            return fail(ProtocolError(ErrorCode.NOT_PAIRED, "The Mac said ready before both sides confirmed."))
        }
        return ready(message)
    }

    private fun ready(message: HandshakeMessage): List<Action> {
        val session = message.session
            ?: return fail(ProtocolError(ErrorCode.INVALID_REQUEST, "The Mac sent no session."))
        step = Step.DONE
        return listOf(Action.Ready(mac!!, macIdentity, session))
    }

    private fun fail(error: ProtocolError): List<Action> {
        if (step == Step.FAILED) return emptyList()
        val sealed = transcript.isNotEmpty()
        step = Step.FAILED
        val message = HandshakeMessage(step = HandshakeStep.ERROR, error = HandshakeError(error.code, error.message))
        return listOf(Action.Send(HandshakeStep.ERROR, message.encode(), sealed), Action.Fail(error))
    }

    private fun base64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)

    private fun unbase64(text: String): ByteArray? = try {
        Base64.getDecoder().decode(text)
    } catch (_: IllegalArgumentException) {
        null
    }
}
