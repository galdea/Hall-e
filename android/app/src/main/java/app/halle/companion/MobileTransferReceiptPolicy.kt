package app.halle.companion

import org.json.JSONObject

/** Structural receipt checks; the transfer worker authenticates the MAC with the workspace key. */
internal object MobileTransferReceiptPolicy {
    private val SHA256 = Regex("^[0-9a-f]{64}$")

    fun isBound(receiptJson: String, recordingId: String, audioSHA256: String, transcriptSHA256: String): Boolean = runCatching {
        if (!SHA256.matches(audioSHA256) || !SHA256.matches(transcriptSHA256)) return false
        val receipt = JSONObject(receiptJson)
        receipt.getInt("v") == 1 &&
            receipt.getInt("protocolVersion") == 1 &&
            receipt.getString("recordingId") == recordingId &&
            receipt.getString("audioSHA256") == audioSHA256 &&
            receipt.getString("transcriptSHA256") == transcriptSHA256 &&
            receipt.getString("transferId").isNotBlank() &&
            receipt.getString("workspaceId").isNotBlank() &&
            receipt.getString("deviceId").isNotBlank() &&
            receipt.getString("macDeviceId").isNotBlank() &&
            receipt.getString("mac").isNotBlank() &&
            receipt.getBoolean("macAudioPurged") &&
            receipt.getLong("plaintextLength") > 0 && receipt.getInt("chunkSize") > 0 &&
            receipt.getInt("chunkCount") > 0 && receipt.getLong("savedAtMs") > 0
    }.getOrDefault(false)
}
