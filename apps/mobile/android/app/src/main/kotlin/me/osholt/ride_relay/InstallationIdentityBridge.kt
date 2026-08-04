package me.osholt.ride_relay

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.KeyStoreException
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.ProviderException
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.NamedParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.json.JSONObject

/**
 * Protocol-2 installation identity bridge.
 *
 * Curve keys are generated directly in Android Keystore only when the device
 * proves that both Ed25519 and X25519 work there. Android's documented
 * Keystore algorithm set does not guarantee those curves, so the portable
 * fallback encrypts the raw curve keys under an app-scoped, non-exportable
 * AES-GCM Keystore key. Private key bytes never cross the Flutter channel.
 */
class InstallationIdentityBridge(context: Context) {
    companion object {
        const val CHANNEL_NAME = "me.osholt.ride_relay/installation_identity"

        private const val PREFERENCES_NAME = "protocol2_installation_identity"
        private const val RECORD_KEY = "identity_v1"
        private const val WRAPPING_KEY_ALIAS = "tailendcharlie.protocol2.identity.wrap.v1"
        private const val SIGNING_KEY_ALIAS = "tailendcharlie.protocol2.identity.sign.v1"
        private const val AGREEMENT_KEY_ALIAS = "tailendcharlie.protocol2.identity.agree.v1"
        private const val BACKEND_WRAPPED = "android_keystore_wrapped_curve25519"
        private const val BACKEND_DIRECT = "android_keystore_non_exportable_curve25519"
        private const val PRIVATE_MATERIAL_SIZE = 65
        private val identityLock = Any()
        private var createdThisProcessKeyId: String? = null
    }

    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val secureRandom = SecureRandom()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        synchronized(identityLock) {
            try {
                when (call.method) {
                    "getOrCreate" -> {
                        result.success(getOrCreate(call.argument<String>("expectedKeyId")))
                    }
                    "sign" -> {
                        val keyId = call.argument<String>("keyId")
                            ?: throw IdentityException("invalid_arguments")
                        val data = call.argument<ByteArray>("data")
                            ?: throw IdentityException("invalid_arguments")
                        result.success(sign(requireIdentity(keyId), data))
                    }
                    "deriveSharedSecret" -> {
                        val keyId = call.argument<String>("keyId")
                            ?: throw IdentityException("invalid_arguments")
                        val peer = call.argument<ByteArray>("peerPublicKey")
                            ?: throw IdentityException("invalid_arguments")
                        if (peer.size != 32) throw IdentityException("invalid_arguments")
                        result.success(deriveSharedSecret(requireIdentity(keyId), peer))
                    }
                    else -> result.notImplemented()
                }
            } catch (error: IdentityException) {
                result.error(error.code, error.safeMessage, null)
            } catch (_: Throwable) {
                result.error(
                    "identity_operation_failed",
                    "The installation identity operation failed.",
                    null,
                )
            }
        }
    }

    private fun getOrCreate(expectedKeyId: String?): Map<String, Any> =
        when (val loaded = loadStoredIdentity()) {
            is IdentityLoad.Valid -> {
                val publicIdentity = loaded.material.publicIdentity
                when {
                    expectedKeyId != null && expectedKeyId == publicIdentity.keyId ->
                        publicIdentity.channelValue("reused", false)
                    expectedKeyId != null -> replaceIdentity("key_mismatch")
                    createdThisProcessKeyId == publicIdentity.keyId ->
                        publicIdentity.channelValue("reused", false)
                    else -> replaceIdentity("public_record_missing")
                }
            }
            IdentityLoad.Missing -> createIdentity(
                lifecycleEvent = if (expectedKeyId == null) "created" else "secure_material_missing",
                identityChanged = expectedKeyId != null,
            )
            IdentityLoad.Corrupt -> replaceIdentity("corrupt_secure_material")
            IdentityLoad.Unavailable -> throw IdentityException("secure_storage_unavailable")
        }

    private fun replaceIdentity(lifecycleEvent: String): Map<String, Any> {
        deleteIdentityMaterial()
        return createIdentity(lifecycleEvent, true)
    }

    private fun createIdentity(
        lifecycleEvent: String,
        identityChanged: Boolean,
    ): Map<String, Any> {
        val direct = tryCreateDirectIdentity()
        val material = direct ?: createWrappedIdentity()
        persist(material)
        createdThisProcessKeyId = material.publicIdentity.keyId
        return material.publicIdentity.channelValue(lifecycleEvent, identityChanged)
    }

    private fun createWrappedIdentity(): IdentityMaterial {
        val signingPrivate = Ed25519PrivateKeyParameters(secureRandom)
        val agreementPrivate = X25519PrivateKeyParameters(secureRandom)
        val privateBytes = ByteBuffer.allocate(PRIVATE_MATERIAL_SIZE)
            .put(1)
            .put(signingPrivate.encoded)
            .put(agreementPrivate.encoded)
            .array()
        val wrappedPrivateMaterial = try {
            encryptPrivateMaterial(privateBytes)
        } finally {
            privateBytes.fill(0)
        }
        return IdentityMaterial(
            backend = BACKEND_WRAPPED,
            signingPublicKey = signingPrivate.generatePublicKey().encoded,
            agreementPublicKey = agreementPrivate.generatePublicKey().encoded,
            wrappedPrivateMaterial = wrappedPrivateMaterial,
            hardwareBacked = isWrappingKeyHardwareBacked(),
        )
    }

    private fun tryCreateDirectIdentity(): IdentityMaterial? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return try {
            val keyStore = androidKeyStore()
            keyStore.deleteEntry(SIGNING_KEY_ALIAS)
            keyStore.deleteEntry(AGREEMENT_KEY_ALIAS)

            val signingGenerator = KeyPairGenerator.getInstance("Ed25519", "AndroidKeyStore")
            signingGenerator.initialize(
                KeyGenParameterSpec.Builder(
                    SIGNING_KEY_ALIAS,
                    KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
                )
                    .setDigests(KeyProperties.DIGEST_NONE)
                    .build(),
            )
            val signingPair = signingGenerator.generateKeyPair()

            val agreementGenerator = KeyPairGenerator.getInstance("XDH", "AndroidKeyStore")
            agreementGenerator.initialize(
                KeyGenParameterSpec.Builder(
                    AGREEMENT_KEY_ALIAS,
                    KeyProperties.PURPOSE_AGREE_KEY,
                )
                    .setAlgorithmParameterSpec(NamedParameterSpec("X25519"))
                    .build(),
            )
            val agreementPair = agreementGenerator.generateKeyPair()
            val signingPublic = rawPublicKey(signingPair.public.encoded)
            val agreementPublic = rawPublicKey(agreementPair.public.encoded)
            if (signingPublic.size != 32 || agreementPublic.size != 32) {
                throw IllegalStateException("Unexpected public key size")
            }

            val material = IdentityMaterial(
                backend = BACKEND_DIRECT,
                signingPublicKey = signingPublic,
                agreementPublicKey = agreementPublic,
                wrappedPrivateMaterial = null,
                hardwareBacked = isPrivateKeyHardwareBacked(signingPair.private) &&
                    isPrivateKeyHardwareBacked(agreementPair.private),
            )
            selfTestDirectIdentity(material)
            material
        } catch (_: Throwable) {
            val keyStore = androidKeyStore()
            keyStore.deleteEntry(SIGNING_KEY_ALIAS)
            keyStore.deleteEntry(AGREEMENT_KEY_ALIAS)
            null
        }
    }

    private fun selfTestDirectIdentity(material: IdentityMaterial) {
        val message = "tailendcharlie.protocol2.identity.self-test.v1".toByteArray()
        val signature = sign(material, message)
        val verifier = Ed25519Signer()
        verifier.init(false, Ed25519PublicKeyParameters(material.signingPublicKey, 0))
        verifier.update(message, 0, message.size)
        if (!verifier.verifySignature(signature)) throw IllegalStateException("Signing self-test failed")

        val peerPrivate = X25519PrivateKeyParameters(secureRandom)
        val peerPublic = peerPrivate.generatePublicKey().encoded
        val actual = deriveSharedSecret(material, peerPublic)
        val expectedAgreement = X25519Agreement()
        expectedAgreement.init(peerPrivate)
        val expected = ByteArray(expectedAgreement.agreementSize)
        expectedAgreement.calculateAgreement(
            X25519PublicKeyParameters(material.agreementPublicKey, 0),
            expected,
            0,
        )
        if (!MessageDigest.isEqual(actual, expected)) {
            throw IllegalStateException("Agreement self-test failed")
        }
    }

    private fun loadStoredIdentity(): IdentityLoad {
        val encoded = preferences.getString(RECORD_KEY, null) ?: return IdentityLoad.Missing
        return try {
            val json = JSONObject(encoded)
            if (json.getInt("schemaVersion") != 1) return IdentityLoad.Corrupt
            val backend = json.getString("backend")
            val signingPublic = decode(json.getString("signingPublicKey"))
            val agreementPublic = decode(json.getString("encryptionPublicKey"))
            if (signingPublic.size != 32 || agreementPublic.size != 32) return IdentityLoad.Corrupt
            val material = IdentityMaterial(
                backend = backend,
                signingPublicKey = signingPublic,
                agreementPublicKey = agreementPublic,
                wrappedPrivateMaterial = json.optString("wrappedPrivateMaterial")
                    .takeIf { it.isNotEmpty() }
                    ?.let(::decode),
                hardwareBacked = json.optBoolean("hardwareBacked", false),
            )
            val expected = PublicIdentity(
                signingPublicKey = signingPublic,
                agreementPublicKey = agreementPublic,
                backend = backend,
                hardwareBacked = material.hardwareBacked,
            )
            if (json.getString("keyId") != expected.keyId ||
                json.getString("installationFingerprint") != expected.installationFingerprint
            ) {
                return IdentityLoad.Corrupt
            }
            when (backend) {
                BACKEND_WRAPPED -> validateWrappedMaterial(material)
                BACKEND_DIRECT -> validateDirectMaterial(material)
                else -> return IdentityLoad.Corrupt
            }
            IdentityLoad.Valid(material)
        } catch (error: Throwable) {
            if (error is ProviderException || error is KeyStoreException) {
                IdentityLoad.Unavailable
            } else {
                IdentityLoad.Corrupt
            }
        }
    }

    private fun validateWrappedMaterial(material: IdentityMaterial) {
        val privateBytes = decryptPrivateMaterial(
            material.wrappedPrivateMaterial ?: throw IllegalStateException("Missing private material"),
        )
        if (privateBytes.size != PRIVATE_MATERIAL_SIZE || privateBytes[0].toInt() != 1) {
            throw IllegalStateException("Invalid private material")
        }
        try {
            val signingPrivate = Ed25519PrivateKeyParameters(privateBytes, 1)
            val agreementPrivate = X25519PrivateKeyParameters(privateBytes, 33)
            if (!MessageDigest.isEqual(signingPrivate.generatePublicKey().encoded, material.signingPublicKey) ||
                !MessageDigest.isEqual(agreementPrivate.generatePublicKey().encoded, material.agreementPublicKey)
            ) {
                throw IllegalStateException("Private/public key mismatch")
            }
        } finally {
            privateBytes.fill(0)
        }
    }

    private fun validateDirectMaterial(material: IdentityMaterial) {
        val keyStore = androidKeyStore()
        val signing = keyStore.getCertificate(SIGNING_KEY_ALIAS)?.publicKey
            ?: throw IllegalStateException("Signing key missing")
        val agreement = keyStore.getCertificate(AGREEMENT_KEY_ALIAS)?.publicKey
            ?: throw IllegalStateException("Agreement key missing")
        if (!MessageDigest.isEqual(rawPublicKey(signing.encoded), material.signingPublicKey) ||
            !MessageDigest.isEqual(rawPublicKey(agreement.encoded), material.agreementPublicKey)
        ) {
            throw IllegalStateException("Keystore/public key mismatch")
        }
    }

    private fun requireIdentity(keyId: String): IdentityMaterial {
        val loaded = loadStoredIdentity()
        if (loaded == IdentityLoad.Unavailable) {
            throw IdentityException("secure_storage_unavailable")
        }
        if (loaded !is IdentityLoad.Valid) throw IdentityException("identity_unavailable")
        if (loaded.material.publicIdentity.keyId != keyId) {
            throw IdentityException("identity_key_mismatch")
        }
        return loaded.material
    }

    private fun sign(material: IdentityMaterial, data: ByteArray): ByteArray =
        when (material.backend) {
            BACKEND_WRAPPED -> {
                val privateBytes = decryptPrivateMaterial(material.wrappedPrivateMaterial!!)
                try {
                    val signer = Ed25519Signer()
                    signer.init(true, Ed25519PrivateKeyParameters(privateBytes, 1))
                    signer.update(data, 0, data.size)
                    signer.generateSignature()
                } finally {
                    privateBytes.fill(0)
                }
            }
            BACKEND_DIRECT -> {
                val privateKey = androidKeyStore().getKey(SIGNING_KEY_ALIAS, null) as? PrivateKey
                    ?: throw IdentityException("identity_unavailable")
                Signature.getInstance("Ed25519").run {
                    initSign(privateKey)
                    update(data)
                    sign()
                }
            }
            else -> throw IdentityException("identity_unavailable")
        }

    private fun deriveSharedSecret(material: IdentityMaterial, peerPublicKey: ByteArray): ByteArray =
        when (material.backend) {
            BACKEND_WRAPPED -> {
                val privateBytes = decryptPrivateMaterial(material.wrappedPrivateMaterial!!)
                try {
                    val agreement = X25519Agreement()
                    agreement.init(X25519PrivateKeyParameters(privateBytes, 33))
                    ByteArray(agreement.agreementSize).also {
                        agreement.calculateAgreement(X25519PublicKeyParameters(peerPublicKey, 0), it, 0)
                    }
                } finally {
                    privateBytes.fill(0)
                }
            }
            BACKEND_DIRECT -> {
                val privateKey = androidKeyStore().getKey(AGREEMENT_KEY_ALIAS, null) as? PrivateKey
                    ?: throw IdentityException("identity_unavailable")
                val encodedPeer = SubjectPublicKeyInfo(
                    AlgorithmIdentifier(ASN1ObjectIdentifier("1.3.101.110")),
                    peerPublicKey,
                ).encoded
                val peer = KeyFactory.getInstance("XDH").generatePublic(X509EncodedKeySpec(encodedPeer))
                KeyAgreement.getInstance("XDH").run {
                    init(privateKey)
                    doPhase(peer, true)
                    generateSecret()
                }
            }
            else -> throw IdentityException("identity_unavailable")
        }

    private fun persist(material: IdentityMaterial) {
        val publicIdentity = material.publicIdentity
        val json = JSONObject()
            .put("schemaVersion", 1)
            .put("backend", material.backend)
            .put("keyId", publicIdentity.keyId)
            .put("installationFingerprint", publicIdentity.installationFingerprint)
            .put("signingPublicKey", encode(material.signingPublicKey))
            .put("encryptionPublicKey", encode(material.agreementPublicKey))
            .put("hardwareBacked", material.hardwareBacked)
        material.wrappedPrivateMaterial?.let {
            json.put("wrappedPrivateMaterial", encode(it))
        }
        if (!preferences.edit().putString(RECORD_KEY, json.toString()).commit()) {
            throw IdentityException("secure_storage_failed")
        }
    }

    private fun encryptPrivateMaterial(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateWrappingKey())
        val ciphertext = cipher.doFinal(plaintext)
        return ByteBuffer.allocate(1 + cipher.iv.size + ciphertext.size)
            .put(cipher.iv.size.toByte())
            .put(cipher.iv)
            .put(ciphertext)
            .array()
    }

    private fun decryptPrivateMaterial(blob: ByteArray): ByteArray {
        if (blob.size < 14) throw IllegalStateException("Invalid wrapped key")
        val ivSize = blob[0].toInt() and 0xff
        if (ivSize !in 12..16 || blob.size <= 1 + ivSize) throw IllegalStateException("Invalid IV")
        val iv = blob.copyOfRange(1, 1 + ivSize)
        val ciphertext = blob.copyOfRange(1 + ivSize, blob.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getWrappingKey(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun getOrCreateWrappingKey(): SecretKey {
        val keyStore = androidKeyStore()
        (keyStore.getKey(WRAPPING_KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    WRAPPING_KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            generateKey()
        }
    }

    private fun getWrappingKey(): SecretKey =
        androidKeyStore().getKey(WRAPPING_KEY_ALIAS, null) as? SecretKey
            ?: throw IllegalStateException("Wrapping key missing")

    @Suppress("DEPRECATION")
    private fun isWrappingKeyHardwareBacked(): Boolean = try {
        val key = getWrappingKey()
        val factory = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
        val info = factory.getKeySpec(key, KeyInfo::class.java) as KeyInfo
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT ||
                info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX
        } else {
            info.isInsideSecureHardware
        }
    } catch (_: Throwable) {
        false
    }

    @Suppress("DEPRECATION")
    private fun isPrivateKeyHardwareBacked(key: PrivateKey): Boolean = try {
        val factory = KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
        val info = factory.getKeySpec(key, KeyInfo::class.java) as KeyInfo
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT ||
                info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX
        } else {
            info.isInsideSecureHardware
        }
    } catch (_: Throwable) {
        false
    }

    private fun deleteIdentityMaterial() {
        preferences.edit().remove(RECORD_KEY).commit()
        val keyStore = androidKeyStore()
        keyStore.deleteEntry(SIGNING_KEY_ALIAS)
        keyStore.deleteEntry(AGREEMENT_KEY_ALIAS)
        keyStore.deleteEntry(WRAPPING_KEY_ALIAS)
    }

    private fun androidKeyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun rawPublicKey(encoded: ByteArray): ByteArray =
        SubjectPublicKeyInfo.getInstance(encoded).publicKeyData.bytes

    private fun encode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)

    private fun decode(value: String): ByteArray =
        Base64.decode(value, Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)
}

private sealed interface IdentityLoad {
    data object Missing : IdentityLoad
    data object Corrupt : IdentityLoad
    data object Unavailable : IdentityLoad
    data class Valid(val material: IdentityMaterial) : IdentityLoad
}

private data class IdentityMaterial(
    val backend: String,
    val signingPublicKey: ByteArray,
    val agreementPublicKey: ByteArray,
    val wrappedPrivateMaterial: ByteArray?,
    val hardwareBacked: Boolean,
) {
    val publicIdentity: PublicIdentity
        get() = PublicIdentity(
            signingPublicKey = signingPublicKey,
            agreementPublicKey = agreementPublicKey,
            backend = backend,
            hardwareBacked = hardwareBacked,
        )
}

private data class PublicIdentity(
    val signingPublicKey: ByteArray,
    val agreementPublicKey: ByteArray,
    val backend: String,
    val hardwareBacked: Boolean,
) {
    val keyId: String = identifier(
        prefix = "p2k1_",
        label = "tailendcharlie.protocol2.signing-key-id.v1",
        publicKey = signingPublicKey,
        byteCount = 16,
    )
    val installationFingerprint: String = identifier(
        prefix = "ifp1_",
        label = "tailendcharlie.installation-fingerprint.v1",
        publicKey = signingPublicKey,
        byteCount = 32,
    )

    fun channelValue(lifecycleEvent: String, identityChanged: Boolean): Map<String, Any> =
        mapOf(
            "schemaVersion" to 1,
            "keyId" to keyId,
            "installationFingerprint" to installationFingerprint,
            "signingPublicKey" to signingPublicKey,
            "encryptionPublicKey" to agreementPublicKey,
            "storageProtection" to when {
                backend == "android_keystore_non_exportable_curve25519" ->
                    "android_keystore_non_exportable_curve25519"
                hardwareBacked -> "android_keystore_hardware_wrapped_curve25519"
                else -> "android_keystore_software_wrapped_curve25519"
            },
            "hardwareBacked" to hardwareBacked,
            "wrappedKeyFallback" to
                (backend == "android_keystore_wrapped_curve25519"),
            "lifecycleEvent" to lifecycleEvent,
            "identityChanged" to identityChanged,
        )

    companion object {
        private fun identifier(
            prefix: String,
            label: String,
            publicKey: ByteArray,
            byteCount: Int,
        ): String {
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(label.toByteArray(Charsets.UTF_8))
            digest.update(byteArrayOf(0))
            digest.update(publicKey)
            val value = digest.digest().copyOf(byteCount)
            return prefix + Base64.encodeToString(
                value,
                Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING,
            )
        }
    }
}

private class IdentityException(val code: String) : RuntimeException() {
    val safeMessage: String
        get() = when (code) {
            "invalid_arguments" -> "The installation identity request is invalid."
            "identity_unavailable" -> "The private installation identity is missing or corrupt."
            "identity_key_mismatch" -> "The requested key does not match this installation identity."
            "secure_storage_failed" -> "The installation identity could not be stored securely."
            "secure_storage_unavailable" -> "Unlock the device before using its installation identity."
            else -> "The installation identity operation failed."
        }
}
