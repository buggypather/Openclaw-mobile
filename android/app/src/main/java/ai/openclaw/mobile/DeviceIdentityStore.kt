package ai.openclaw.mobile

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class DeviceIdentity(val id: String, val publicKey: String, val privateKey: ByteArray)
data class DeviceToken(val token: String, val role: String, val scopes: Set<String>)

/**
 * Small Android-only secret store. The AES key never leaves Android Keystore;
 * SharedPreferences contains only AES/GCM ciphertext. This avoids pulling the
 * AndroidX Security runtime into the APK while retaining encrypted-at-rest
 * device identity and Gateway tokens.
 */
class DeviceIdentityStore(context: Context) {
    private val prefs = context.getSharedPreferences("openclaw-device-secrets-v2", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun b64d(value: String) = Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun key(): SecretKey {
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }

    private fun seal(plain: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(plain)
        val packed = ByteArray(1 + iv.size + encrypted.size)
        packed[0] = iv.size.toByte()
        System.arraycopy(iv, 0, packed, 1, iv.size)
        System.arraycopy(encrypted, 0, packed, 1 + iv.size, encrypted.size)
        return b64(packed)
    }

    private fun open(value: String): ByteArray {
        val packed = b64d(value)
        val ivSize = packed[0].toInt() and 0xff
        require(ivSize in 12..32 && packed.size > 1 + ivSize) { "Invalid encrypted secret" }
        val iv = packed.copyOfRange(1, 1 + ivSize)
        val ciphertext = packed.copyOfRange(1 + ivSize, packed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun getSecret(name: String): String? = prefs.getString(name, null)?.let { runCatching { String(open(it), Charsets.UTF_8) }.getOrNull() }
    private fun putSecret(name: String, value: String) { prefs.edit().putString(name, seal(value.toByteArray(Charsets.UTF_8))).apply() }

    fun identity(): DeviceIdentity {
        val raw = getSecret("ed25519-private")?.let(::b64d)
            ?: Ed25519PrivateKeyParameters(java.security.SecureRandom()).encoded.also { putSecret("ed25519-private", b64(it)) }
        val privateKey = Ed25519PrivateKeyParameters(raw, 0)
        val publicKey = privateKey.generatePublicKey().encoded
        val id = MessageDigest.getInstance("SHA-256").digest(publicKey).joinToString("") { "%02x".format(it) }
        return DeviceIdentity(id, b64(publicKey), raw)
    }

    fun token(): DeviceToken? {
        val token = getSecret("device-token") ?: return null
        val role = getSecret("device-role") ?: "operator"
        val scopes = getSecret("device-scopes")?.split('\n')?.filter { it.isNotBlank() }?.toSet() ?: emptySet()
        return DeviceToken(token, role, scopes)
    }

    fun saveToken(token: String, role: String, scopes: Set<String>) {
        putSecret("device-token", token)
        putSecret("device-role", role)
        putSecret("device-scopes", scopes.sorted().joinToString("\n"))
    }

    fun clearToken() {
        prefs.edit().remove("device-token").remove("device-role").remove("device-scopes").apply()
    }

    fun sign(identity: DeviceIdentity, payload: String): String {
        val signer = Ed25519Signer()
        signer.init(true, Ed25519PrivateKeyParameters(identity.privateKey, 0))
        val bytes = payload.toByteArray(Charsets.UTF_8)
        signer.update(bytes, 0, bytes.size)
        return b64(signer.generateSignature())
    }

    companion object { private const val KEY_ALIAS = "openclaw-device-secrets-aes" }
}
