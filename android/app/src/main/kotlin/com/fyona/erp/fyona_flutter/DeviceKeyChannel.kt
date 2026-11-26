package com.fyona.erp.fyona_flutter

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * Device identity for trusted-device sign-in (docs/AUTH_PLAN.md).
 *
 * One ECDSA P-256 key pair per install, generated INSIDE the Android
 * Keystore (StrongBox when the phone has it, otherwise the TEE). The private
 * key never leaves the secure hardware: only the public key (X.509
 * SubjectPublicKeyInfo DER) and signatures (DER, SHA256withECDSA) cross the
 * channel.
 *
 * Channel `com.fyona.erp/device_identity`:
 *  - ensure      → {created: Boolean, public_key: String, strongbox: Boolean}
 *  - publicKey   → String (base64 SPKI DER)
 *  - sign {message: String} → String (base64 DER signature over UTF-8 bytes)
 *  - deviceInfo  → {name, model, os, os_version}
 */
internal object DeviceKeyChannel {
    const val NAME = "com.fyona.erp/device_identity"
    private const val ALIAS = "fyona_device_identity_v1"
    private const val KEYSTORE = "AndroidKeyStore"
    private const val STRONGBOX_FEATURE = "android.hardware.strongbox_keystore"

    @Volatile
    private var strongBoxBacked = false

    fun register(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        val main = Handler(Looper.getMainLooper())
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            // Key generation on StrongBox can take a few hundred ms: never on
            // the UI thread. Results are always delivered on the main thread.
            val method = call.method
            if (method != "ensure" && method != "publicKey" &&
                method != "sign" && method != "deviceInfo") {
                result.notImplemented()
            } else {
                val message: String? = call.argument<String>("message")
                Thread(Runnable {
                    try {
                        val value: Any = when (method) {
                            "ensure" -> {
                                val created = ensureKey(appContext)
                                mapOf(
                                    "created" to created,
                                    "public_key" to publicKey(appContext),
                                    "strongbox" to strongBoxBacked
                                )
                            }
                            "publicKey" -> publicKey(appContext)
                            "sign" -> sign(
                                appContext,
                                message ?: throw IllegalArgumentException("message missing")
                            )
                            else -> deviceInfo(appContext)
                        }
                        main.post { result.success(value) }
                    } catch (e: Exception) {
                        val code = e.javaClass.simpleName
                        main.post { result.error("device_key", code, null) }
                    }
                }).start()
            }
        }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    /** Creates the key pair when missing. Returns true when a NEW key was made. */
    @Synchronized
    private fun ensureKey(context: Context): Boolean {
        val ks = keyStore()
        if (ks.containsAlias(ALIAS)) return false
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE)
        val wantStrongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            context.packageManager.hasSystemFeature(STRONGBOX_FEATURE)
        if (wantStrongBox) {
            try {
                generator.initialize(spec(true))
                generator.generateKeyPair()
                strongBoxBacked = true
                return true
            } catch (_: Exception) {
                // StrongBoxUnavailableException or a vendor quirk: fall back
                // to the TEE-backed keystore below.
                try { keyStore().deleteEntry(ALIAS) } catch (_: Exception) {}
            }
        }
        generator.initialize(spec(false))
        generator.generateKeyPair()
        strongBoxBacked = false
        return true
    }

    private fun spec(strongBox: Boolean): KeyGenParameterSpec {
        val builder = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        return builder.build()
    }

    private fun publicKey(context: Context): String {
        ensureKey(context)
        val cert = keyStore().getCertificate(ALIAS)
            ?: throw IllegalStateException("no certificate")
        // X.509 SubjectPublicKeyInfo DER.
        return Base64.encodeToString(cert.publicKey.encoded, Base64.NO_WRAP)
    }

    private fun sign(context: Context, message: String): String {
        ensureKey(context)
        val key = keyStore().getKey(ALIAS, null) as? PrivateKey
            ?: throw IllegalStateException("no private key")
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(key)
        signer.update(message.toByteArray(Charsets.UTF_8))
        // ASN.1 DER (SEQUENCE { r INTEGER, s INTEGER }).
        return Base64.encodeToString(signer.sign(), Base64.NO_WRAP)
    }

    private fun deviceInfo(context: Context): Map<String, String> {
        val manufacturer = (Build.MANUFACTURER ?: "").trim()
        val model = (Build.MODEL ?: "").trim()
        var name = ""
        try {
            name = Settings.Global.getString(context.contentResolver, "device_name") ?: ""
        } catch (_: Exception) {}
        if (name.isBlank()) {
            name = listOf(manufacturer.replaceFirstChar { it.uppercase() }, model)
                .filter { it.isNotBlank() }
                .joinToString(" ")
        }
        if (name.isBlank()) name = "Android"
        return mapOf(
            "name" to name.trim(),
            "model" to (if (model.isNotBlank()) model else "Android"),
            "os" to "Android",
            "os_version" to (Build.VERSION.RELEASE ?: "")
        )
    }
}
