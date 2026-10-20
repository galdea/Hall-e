package app.halle.companion

import org.json.JSONObject
import java.nio.charset.StandardCharsets
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Cross-platform wire primitives shared with Hall-e for Mac. */
internal object PhoneAudioTransferCrypto {
    fun deriveKey(workspaceKey: ByteArray, purpose: String): ByteArray {
        val label = "halle-phone-audio-key-v1\n$purpose".toByteArray(StandardCharsets.UTF_8)
        return Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(workspaceKey, "HmacSHA256"))
        }.doFinal(label)
    }

    fun chunkAAD(manifest: JSONObject, index: Int): ByteArray {
        val fields = listOf("v", "protocolVersion", "workspaceId", "deviceId", "macDeviceId", "transferId", "recordingId",
            "audioSHA256", "plaintextLength", "chunkSize", "chunkCount")
        return ("halle-phone-audio-v1\n" + fields.joinToString("\n") { manifest.get(it).toString() } + "\n" + index)
            .toByteArray(StandardCharsets.UTF_8)
    }

    fun encryptChunk(plaintext: ByteArray, workspaceKey: ByteArray, manifest: JSONObject, index: Int): ByteArray {
        val aad = chunkAAD(manifest, index)
        val nonceMac = Mac.getInstance("HmacSHA256")
        nonceMac.init(SecretKeySpec(deriveKey(workspaceKey, "audio-nonce"), "HmacSHA256"))
        val nonce = nonceMac.doFinal(aad).copyOf(12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(deriveKey(workspaceKey, "audio-encryption"), "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return nonce + cipher.doFinal(plaintext)
    }

    fun receiptCanonical(receipt: JSONObject): String {
        val fields = listOf("v", "protocolVersion", "transferId", "workspaceId", "deviceId", "macDeviceId", "recordingId",
            "audioSHA256", "plaintextLength", "chunkSize", "chunkCount", "transcriptSHA256", "macAudioPurged", "savedAtMs")
        return "halle-phone-audio-receipt-v1\n" + fields.joinToString("\n") { receipt.get(it).toString() }
    }

    fun receiptMAC(workspaceKey: ByteArray, receipt: JSONObject): ByteArray = Mac.getInstance("HmacSHA256").apply {
        init(SecretKeySpec(deriveKey(workspaceKey, "transcript-receipt"), "HmacSHA256"))
    }.doFinal(receiptCanonical(receipt).toByteArray(StandardCharsets.UTF_8))
}
