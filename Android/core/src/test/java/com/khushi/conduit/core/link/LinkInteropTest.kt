package com.khushi.conduit.core.link

import com.khushi.conduit.core.protocol.ControlType
import com.khushi.conduit.core.protocol.DeviceInfo
import com.khushi.conduit.core.protocol.ErrorCode
import com.khushi.conduit.core.protocol.Frame
import com.khushi.conduit.core.protocol.FrameDecoder
import com.khushi.conduit.core.protocol.HandshakeIntent
import com.khushi.conduit.core.protocol.HandshakeMessage
import com.khushi.conduit.core.protocol.HandshakeStep
import com.khushi.conduit.core.protocol.LinkChannel
import com.khushi.conduit.core.protocol.LinkCrypto
import com.khushi.conduit.core.protocol.Platform
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec

/**
 * Against a real, running Conduit for Mac — opt-in, because it needs one:
 *
 *     CONDUIT_MAC=127.0.0.1:47384 ./gradlew :core:testDebugUnitTest --tests '*LinkInteropTest*'
 *
 * An unpaired phone asking to connect must get a `not_paired` error back.
 * That only happens if the Mac read this phone's hello — its JSON, its key,
 * and a device ID Kotlin computed the way Swift does — and this phone read
 * the Mac's answer, so both languages' framing and encoding meet on the wire.
 */
class LinkInteropTest {

    @Test
    fun aRunningMacRefusesAPhoneItHasNotPaired() {
        val target = System.getenv("CONDUIT_MAC") ?: return
        val (host, port) = target.split(":").let { it[0] to it[1].toInt() }

        val pair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec(LinkCrypto.CURVE))
            generateKeyPair()
        }
        val signer = object : LinkSigner {
            override val publicKey = LinkCrypto.encodePublicKey(pair.public)
            override fun sign(statement: ByteArray) = LinkCrypto.sign(statement, pair.private)
        }
        val device = DeviceInfo(id = LinkCrypto.deviceId(signer.publicKey), name = "Interop test", platform = Platform.ANDROID)
        val handshake = PhoneHandshake(signer, device, HandshakeIntent.CONNECT)

        Socket(host, port).use { socket ->
            socket.soTimeout = 5_000
            val hello = handshake.start().filterIsInstance<PhoneHandshake.Action.Send>().single()
            socket.getOutputStream().write(Frame(LinkChannel.CONTROL, ControlType.HANDSHAKE, hello.payload).encode())

            val decoder = FrameDecoder()
            val buffer = ByteArray(16 * 1024)
            var answer: HandshakeMessage? = null
            while (answer == null) {
                val count = socket.getInputStream().read(buffer)
                check(count > 0) { "the Mac closed the connection without answering" }
                answer = decoder.receive(buffer.copyOf(count))
                    .firstOrNull { it.channel == LinkChannel.CONTROL && it.type == ControlType.HANDSHAKE }
                    ?.let { HandshakeMessage.decode(it.payload) }
            }

            assertEquals(HandshakeStep.ERROR, answer.step)
            assertEquals(ErrorCode.NOT_PAIRED, answer.error?.code)
        }
    }
}
