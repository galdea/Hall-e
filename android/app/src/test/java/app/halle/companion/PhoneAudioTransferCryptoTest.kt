package app.halle.companion

import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class PhoneAudioTransferCryptoTest {
    private val key = ByteArray(32) { 1 }
    private val manifest = JSONObject()
        .put("v", 1).put("protocolVersion", 1)
        .put("workspaceId", "10000000-0000-4000-8000-000000000001")
        .put("deviceId", "20000000-0000-4000-8000-000000000001")
        .put("macDeviceId", "30000000-0000-4000-8000-000000000001")
        .put("transferId", "40000000-0000-4000-8000-000000000001")
        .put("recordingId", "50000000-0000-4000-8000-000000000001")
        .put("audioSHA256", "a".repeat(64)).put("plaintextLength", 3)
        .put("chunkSize", 262144).put("chunkCount", 1)

    @Test fun sharedPhoneMacCryptoKnownVector() {
        assertEquals("9bda2e3cdc3810ba70d652d670aea1e14bdd5446e27d66bce1630454f96e4244",
            PhoneAudioTransferCrypto.deriveKey(key, "audio-encryption").hex())
        assertEquals("halle-phone-audio-v1\n1\n1\n10000000-0000-4000-8000-000000000001\n" +
            "20000000-0000-4000-8000-000000000001\n30000000-0000-4000-8000-000000000001\n" +
            "40000000-0000-4000-8000-000000000001\n50000000-0000-4000-8000-000000000001\n" +
            "${"a".repeat(64)}\n3\n262144\n1\n0", String(PhoneAudioTransferCrypto.chunkAAD(manifest, 0)))
        assertEquals("44f5771563d0c1f51c5359243f95605eba95f24915098a600cabbed9325cc7",
            PhoneAudioTransferCrypto.encryptChunk("abc".toByteArray(), key, manifest, 0).hex())

        val receipt = JSONObject().put("v", 1).put("protocolVersion", 1)
            .put("transferId", manifest.getString("transferId")).put("workspaceId", manifest.getString("workspaceId"))
            .put("deviceId", manifest.getString("deviceId")).put("macDeviceId", manifest.getString("macDeviceId"))
            .put("recordingId", manifest.getString("recordingId")).put("audioSHA256", "a".repeat(64))
            .put("plaintextLength", 3).put("chunkSize", 262144).put("chunkCount", 1)
            .put("transcriptSHA256", "b".repeat(64)).put("macAudioPurged", true).put("savedAtMs", 1700000000000L)
        assertEquals("0OmdHJEiKJOnUvDTDe3U24_60X48OtuCiRufSX2Jfd8",
            Base64.getUrlEncoder().withoutPadding().encodeToString(PhoneAudioTransferCrypto.receiptMAC(key, receipt)))
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
}
