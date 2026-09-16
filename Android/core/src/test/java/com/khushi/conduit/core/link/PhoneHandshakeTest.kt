package com.khushi.conduit.core.link

import com.khushi.conduit.core.protocol.DeviceInfo
import com.khushi.conduit.core.protocol.ErrorCode
import com.khushi.conduit.core.protocol.HandshakeIntent
import com.khushi.conduit.core.protocol.HandshakeMessage
import com.khushi.conduit.core.protocol.HandshakeMode
import com.khushi.conduit.core.protocol.HandshakeStep
import com.khushi.conduit.core.protocol.LinkCrypto
import com.khushi.conduit.core.protocol.LinkSessionInfo
import com.khushi.conduit.core.protocol.Platform
import com.khushi.conduit.core.protocol.ProtocolVersion
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.util.Base64

/**
 * The phone's handshake, driven by a Mac written here from the spec — the
 * mirror of ConduitKit's handshake tests, which drive the Mac from a phone.
 * Between the two suites and the shared vectors, both sides of every step are
 * checked against the protocol rather than against each other's code.
 */
class PhoneHandshakeTest {

    private fun keyPair(): KeyPair = KeyPairGenerator.getInstance("EC").run {
        initialize(ECGenParameterSpec(LinkCrypto.CURVE))
        generateKeyPair()
    }

    private fun b64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
    private fun unb64(text: String) = Base64.getDecoder().decode(text)

    private class SoftwareSigner(private val pair: KeyPair) : LinkSigner {
        override val publicKey: ByteArray = LinkCrypto.encodePublicKey(pair.public)
        override fun sign(statement: ByteArray): ByteArray = LinkCrypto.sign(statement, pair.private)
    }

    /** A Mac that follows Shared/Protocol/README.md §5, and nothing else. */
    private inner class SpecMac(val identity: KeyPair = keyPair()) {
        val identityKey = LinkCrypto.encodePublicKey(identity.public)
        val ephemeral = keyPair()
        val ephemeralKey = LinkCrypto.encodePublicKey(ephemeral.public)
        val nonce = ByteArray(32).also(SecureRandom()::nextBytes)
        val device = DeviceInfo(id = LinkCrypto.deviceId(identityKey), name = "MacBook", platform = Platform.MACOS)

        var transcript = ByteArray(0)
        var phoneEphemeral = ByteArray(0)
        var phoneNonce = ByteArray(0)

        fun hello(phoneHello: ByteArray, mode: HandshakeMode, device: DeviceInfo = this.device): ByteArray {
            phoneEphemeral = unb64(HandshakeMessage.decode(phoneHello).ephemeralKey!!)
            val hello = HandshakeMessage(
                step = HandshakeStep.HELLO,
                versions = listOf(ProtocolVersion.CURRENT),
                version = ProtocolVersion.CURRENT,
                device = device,
                identityKey = b64(identityKey),
                ephemeralKey = b64(ephemeralKey),
                mode = mode,
                commitment = if (mode == HandshakeMode.PAIR) {
                    b64(LinkCrypto.pairCommitment(nonce, phoneEphemeral, ephemeralKey))
                } else {
                    null
                },
            ).encode()
            transcript = LinkCrypto.transcript(phoneHello, hello)
            return hello
        }

        fun auth() = HandshakeMessage(
            step = HandshakeStep.AUTH,
            signature = b64(LinkCrypto.sign(LinkCrypto.authStatement(LinkCrypto.Role.MAC, transcript), identity.private)),
        ).encode()

        fun reveal(revealed: ByteArray = nonce) = HandshakeMessage(step = HandshakeStep.PAIR_REVEAL, nonce = b64(revealed)).encode()

        fun confirm() = HandshakeMessage(
            step = HandshakeStep.PAIR_CONFIRM,
            signature = b64(LinkCrypto.sign(
                LinkCrypto.pairStatement(LinkCrypto.Role.MAC, transcript, phoneNonce, nonce), identity.private)),
        ).encode()

        fun ready() = HandshakeMessage(step = HandshakeStep.READY, session = LinkSessionInfo("epoch-1", 15)).encode()

        fun code() = LinkCrypto.pairingCode(phoneEphemeral, ephemeralKey, phoneNonce, nonce)
    }

    private val phoneIdentity = keyPair()
    private val phoneDevice = DeviceInfo(
        id = LinkCrypto.deviceId(LinkCrypto.encodePublicKey(phoneIdentity.public)),
        name = "S24 Ultra",
        platform = Platform.ANDROID,
    )

    private fun phone(intent: HandshakeIntent, expectedMacKey: ByteArray? = null) =
        PhoneHandshake(SoftwareSigner(phoneIdentity), phoneDevice, intent, expectedMacKey)

    private fun List<PhoneHandshake.Action>.sent(step: HandshakeStep): ByteArray? =
        filterIsInstance<PhoneHandshake.Action.Send>().firstOrNull { it.step == step }?.payload

    private fun List<PhoneHandshake.Action>.failure() = filterIsInstance<PhoneHandshake.Action.Fail>().firstOrNull()?.error

    private fun PhoneHandshake.feed(payload: ByteArray) = receive(HandshakeMessage.decode(payload), payload)

    @Test
    fun pairsWhenBothPeopleSeeTheSameDigits() {
        val mac = SpecMac()
        val phone = phone(HandshakeIntent.PAIR)

        val hello = phone.start().sent(HandshakeStep.HELLO)!!
        val afterHello = phone.feed(mac.hello(hello, HandshakeMode.PAIR))
        assertTrue(afterHello.any { it is PhoneHandshake.Action.KeysEstablished })

        // The phone reveals its nonce first; the Mac committed to its own already.
        mac.phoneNonce = unb64(HandshakeMessage.decode(afterHello.sent(HandshakeStep.PAIR_NONCE)!!).nonce!!)

        val shown = phone.feed(mac.reveal()).filterIsInstance<PhoneHandshake.Action.ConfirmPairing>().single()
        assertEquals(mac.code(), shown.code)
        assertEquals("MacBook", shown.mac.name)

        // The phone's confirmation is a signature the Mac can check.
        val confirm = HandshakeMessage.decode(phone.confirmPairing().sent(HandshakeStep.PAIR_CONFIRM)!!)
        assertTrue(LinkCrypto.verify(
            unb64(confirm.signature!!),
            LinkCrypto.pairStatement(LinkCrypto.Role.PHONE, mac.transcript, mac.phoneNonce, mac.nonce),
            LinkCrypto.encodePublicKey(phoneIdentity.public),
        ))

        assertTrue(phone.feed(mac.confirm()).isEmpty())
        val ready = phone.feed(mac.ready()).filterIsInstance<PhoneHandshake.Action.Ready>().single()
        assertArrayEquals(mac.identityKey, ready.macIdentityKey)
        assertEquals(15, ready.session.heartbeatSeconds)
    }

    @Test
    fun reconnectsToThePairedMacWithoutPairing() {
        val mac = SpecMac()
        val phone = phone(HandshakeIntent.CONNECT, expectedMacKey = mac.identityKey)

        val hello = phone.start().sent(HandshakeStep.HELLO)!!
        val auth = HandshakeMessage.decode(phone.feed(mac.hello(hello, HandshakeMode.AUTHENTICATE)).sent(HandshakeStep.AUTH)!!)
        assertTrue(LinkCrypto.verify(
            unb64(auth.signature!!),
            LinkCrypto.authStatement(LinkCrypto.Role.PHONE, mac.transcript),
            LinkCrypto.encodePublicKey(phoneIdentity.public),
        ))

        assertTrue(phone.feed(mac.auth()).isEmpty())
        assertNotNull(phone.feed(mac.ready()).filterIsInstance<PhoneHandshake.Action.Ready>().singleOrNull())
    }

    @Test
    fun refusesAMacThatIsNotTheOnePaired() {
        val paired = SpecMac()
        val impostor = SpecMac()
        val phone = phone(HandshakeIntent.CONNECT, expectedMacKey = paired.identityKey)

        val hello = phone.start().sent(HandshakeStep.HELLO)!!
        assertEquals(ErrorCode.NOT_PAIRED, phone.feed(impostor.hello(hello, HandshakeMode.AUTHENTICATE)).failure()?.code)
    }

    @Test
    fun refusesARevealThatDoesNotMatchTheCommitment() {
        val mac = SpecMac()
        val phone = phone(HandshakeIntent.PAIR)
        val hello = phone.start().sent(HandshakeStep.HELLO)!!
        phone.feed(mac.hello(hello, HandshakeMode.PAIR))

        // A Mac in the middle that changes its nonce after seeing the phone's.
        val swapped = ByteArray(32).also(SecureRandom()::nextBytes)
        assertEquals(ErrorCode.NOT_PAIRED, phone.feed(mac.reveal(swapped)).failure()?.code)
    }

    @Test
    fun doesNotPairUnlessThePersonAskedTo() {
        val mac = SpecMac()
        val phone = phone(HandshakeIntent.CONNECT)
        val hello = phone.start().sent(HandshakeStep.HELLO)!!
        assertEquals(ErrorCode.NOT_PAIRED, phone.feed(mac.hello(hello, HandshakeMode.PAIR)).failure()?.code)
    }

    @Test
    fun refusesReadyBeforeTheMacHasProvedItself() {
        val mac = SpecMac()
        val phone = phone(HandshakeIntent.CONNECT, expectedMacKey = mac.identityKey)
        val hello = phone.start().sent(HandshakeStep.HELLO)!!
        phone.feed(mac.hello(hello, HandshakeMode.AUTHENTICATE))
        assertEquals(ErrorCode.NOT_PAIRED, phone.feed(mac.ready()).failure()?.code)
    }

    @Test
    fun refusesAMacWhoseDeviceIdIsNotItsKey() {
        val mac = SpecMac()
        val phone = phone(HandshakeIntent.PAIR)
        val hello = phone.start().sent(HandshakeStep.HELLO)!!
        val lying = mac.device.copy(id = "a".repeat(32))
        assertEquals(ErrorCode.INVALID_REQUEST, phone.feed(mac.hello(hello, HandshakeMode.PAIR, lying)).failure()?.code)
    }
}
