package com.khushi.conduit.link

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.khushi.conduit.core.link.LinkSigner
import com.khushi.conduit.core.protocol.LinkCrypto
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec

/**
 * This phone's Conduit Link identity: a P-256 key made inside the Android
 * Keystore. The private key never leaves it; only signatures and the public
 * key do.
 */
class KeystoreSigner private constructor(
    private val privateKey: PrivateKey,
    override val publicKey: ByteArray,
) : LinkSigner {

    val deviceId: String get() = LinkCrypto.deviceId(publicKey)

    override fun sign(statement: ByteArray): ByteArray = LinkCrypto.sign(statement, privateKey)

    companion object {
        private const val ALIAS = "conduit-link-identity"

        @Volatile
        private var cached: KeystoreSigner? = null

        fun get(): KeystoreSigner = cached ?: synchronized(this) {
            cached ?: load().also { cached = it }
        }

        private fun load(): KeystoreSigner {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (store.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry)?.let { entry ->
                return KeystoreSigner(entry.privateKey, LinkCrypto.encodePublicKey(entry.certificate.publicKey))
            }
            val pair = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").run {
                initialize(
                    KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                        .setAlgorithmParameterSpec(ECGenParameterSpec(LinkCrypto.CURVE))
                        .setDigests(KeyProperties.DIGEST_SHA256)
                        .build(),
                )
                generateKeyPair()
            }
            return KeystoreSigner(pair.private, LinkCrypto.encodePublicKey(pair.public))
        }
    }
}
