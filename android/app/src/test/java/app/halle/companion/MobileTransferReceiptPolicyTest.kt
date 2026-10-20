package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MobileTransferReceiptPolicyTest {
    private val recordingId = "d290f1ee-6c54-4b01-90e6-d701748f0851"
    private val audioHash = "a".repeat(64)
    private val transcriptHash = "b".repeat(64)

    @Test fun acceptsReceiptBoundToRecordingAndBothHashes() {
        assertTrue(MobileTransferReceiptPolicy.isBound(receipt().toString(), recordingId, audioHash, transcriptHash))
    }

    @Test fun rejectsMismatchedRecordingOrTranscriptHash() {
        assertFalse(MobileTransferReceiptPolicy.isBound(receipt().toString(), "a290f1ee-6c54-4b01-90e6-d701748f0851", audioHash, transcriptHash))
        assertFalse(MobileTransferReceiptPolicy.isBound(receipt().toString(), recordingId, audioHash, "c".repeat(64)))
    }

    @Test fun rejectsMalformedHashesAndIncompleteReceipt() {
        assertFalse(MobileTransferReceiptPolicy.isBound(receipt().toString(), recordingId, "bad", transcriptHash))
        assertFalse(MobileTransferReceiptPolicy.isBound(JSONObject().put("v", 1).toString(), recordingId, audioHash, transcriptHash))
    }

    @Test fun rejectsReceiptWithoutMacAudioPurgeConfirmation() {
        assertFalse(MobileTransferReceiptPolicy.isBound(receipt().put("macAudioPurged", false).toString(), recordingId, audioHash, transcriptHash))
    }

    private fun receipt() = JSONObject()
        .put("v", 1).put("protocolVersion", 1)
        .put("transferId", "transfer-1").put("workspaceId", "workspace-1")
        .put("deviceId", "phone-1").put("macDeviceId", "mac-1")
        .put("recordingId", recordingId).put("audioSHA256", audioHash)
        .put("plaintextLength", 1024).put("chunkSize", 256).put("chunkCount", 4)
        .put("transcriptSHA256", transcriptHash).put("savedAtMs", 1000)
        .put("mac", "opaque-mac").put("macAudioPurged", true)
}
