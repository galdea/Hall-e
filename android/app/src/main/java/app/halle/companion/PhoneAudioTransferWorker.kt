package app.halle.companion

import android.content.Context
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.concurrent.CancellationException

/** Resumable AFTER-STOP upload. It only examines recordings explicitly marked queued. */
object PhoneAudioTransferWorker {
    private const val CHUNK_SIZE = 256 * 1024
    private const val MAX_BYTES = 100L * 1024 * 1024

    fun recipientChoices(context: Context): List<Pair<String, String>> = SharedSessionClient(context).transferConsumers()

    fun selectRecipient(context: Context, deviceId: String) {
        require(recipientChoices(context).any { it.first == deviceId }) { "Select a registered Mac device." }
        context.applicationContext.getSharedPreferences("phone-audio-transfer", Context.MODE_PRIVATE)
            .edit().putString("macDeviceId", deviceId).commit()
        kick(context)
    }

    /** Call after stop and at app startup; retries remain safe and never resume capture. */
    fun kick(context: Context) {
        val app = context.applicationContext
        val scheduler = app.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
        if (scheduler.getPendingJob(JOB_ID) != null) return
        if (PhoneAudioTransferJobService.isRunning()) {
            PhoneAudioTransferJobService.requestAnotherRun()
            return
        }
        val job = JobInfo.Builder(JOB_ID, ComponentName(app, PhoneAudioTransferJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .setBackoffCriteria(2 * 60_000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .build()
        scheduler.schedule(job)
    }

    internal fun perform(context: Context, isCurrent: () -> Boolean = { true }): Boolean {
        ensureCurrent(isCurrent)
        if (BuildConfig.DEBUG && LocalStore(context).previewActive) return true
        if (!SharedSessionClient(context).paired()) return true
        val store = MobileMeetingStore(context)
        var success = true
        for (meeting in store.list().filter { it.transferState in setOf("queued", "uploading", "uploaded", "receipt_received") }) {
            ensureCurrent(isCurrent)
            if (meeting.trashedAtMs != null) continue
            if (runCatching { transfer(context, store, meeting, isCurrent) }.isFailure) success = false
        }
        return success
    }

    private fun transfer(context: Context, store: MobileMeetingStore, meeting: MobileMeeting, isCurrent: () -> Boolean) {
        ensureCurrent(isCurrent)
        val api = SharedSessionClient(context)
        val key = api.transferWorkspaceKey()
        val current = store.find(meeting.id) ?: return
        val state = current.transferState ?: return
        if (current.trashedAtMs != null) return
        if (state == "receipt_received" && current.transferReceiptJson != null) {
            ensureCurrent(isCurrent)
            val savedReceipt = JSONObject(current.transferReceiptJson)
            val audioHash = current.transferAudioSHA256 ?: return
            val transcriptHash = current.transferTranscriptSHA256 ?: return
            val length = savedReceipt.optLong("plaintextLength", -1)
            val chunks = savedReceipt.optInt("chunkCount", -1)
            val target = savedReceipt.optString("macDeviceId")
            if (length !in 1..MAX_BYTES || chunks != ((length + CHUNK_SIZE - 1) / CHUNK_SIZE).toInt() ||
                !verifyReceipt(savedReceipt, key, current.id, current, api.currentWorkspaceId() ?: return,
                    api.currentDeviceId() ?: return, target, audioHash, length, chunks) ||
                savedReceipt.optString("transcriptSHA256") != transcriptHash) error("Saved receipt validation failed.")
            ensureCurrent(isCurrent)
            if (!store.purgeTransferredAudio(current.id, audioHash, transcriptHash, current.transferReceiptJson)) error("Phone audio purge retry did not complete.")
            // purgeTransferredAudio persists the verified receipt before unlinking; this retry path
            // revalidates its HMAC/bindings and idempotently completes that unlink before ACK.
            if (store.audioFileForTransfer(current.id) != null) error("Phone audio remains after receipt purge.")
            ensureCurrent(isCurrent)
            api.acknowledgePhoneTransfer(current.id, transcriptHash)
            ensureCurrent(isCurrent)
            check(store.setTransferState(current.id, "audio_deleted")) { "Could not save the acknowledged transfer state." }
            return
        }
        // Shared metadata is created only after stop; this worker never holds or bypasses a capture lease.
        ensureCurrent(isCurrent)
        api.createSession(current)
        val audio = store.audioFileForTransfer(current.id) ?: error("Queued phone audio is unavailable.")
        require(audio.length() in 1..MAX_BYTES) { "Phone audio exceeds the transfer limit." }
        val audioHash = sha256(audio)
        val recipientPrefs = context.getSharedPreferences("phone-audio-transfer", Context.MODE_PRIVATE)
        val transferId = current.id
        val chunks = ((audio.length() + CHUNK_SIZE - 1) / CHUNK_SIZE).toInt()
        val workspaceId = api.currentWorkspaceId() ?: error("Phone workspace is unavailable.")
        val deviceId = api.currentDeviceId() ?: error("Phone device is unavailable.")
        val manifestKey = "manifest:${current.id}"
        val savedManifest = recipientPrefs.getString(manifestKey, null)?.let(::JSONObject)
        val manifest = if (savedManifest != null) {
            check(savedManifest.getString("workspaceId") == workspaceId && savedManifest.getString("deviceId") == deviceId &&
                savedManifest.getString("recordingId") == (current.sharedSessionId ?: current.id) &&
                savedManifest.getString("audioSHA256") == audioHash && savedManifest.getLong("plaintextLength") == audio.length() &&
                savedManifest.getInt("chunkSize") == CHUNK_SIZE && savedManifest.getInt("chunkCount") == chunks) {
                "Queued audio changed after its immutable transfer manifest was saved."
            }
            savedManifest
        } else {
            val recipient = recipientPrefs.getString("macDeviceId", null)
                ?: api.transferConsumers().singleOrNull()?.first ?: error("Choose a registered Mac to receive this recording.")
            require(recipient != deviceId)
            JSONObject().put("v", 1).put("protocolVersion", 1).put("workspaceId", workspaceId).put("deviceId", deviceId)
                .put("transferId", transferId).put("recordingId", current.sharedSessionId ?: current.id)
                .put("macDeviceId", recipient).put("audioSHA256", audioHash).put("plaintextLength", audio.length())
                .put("chunkSize", CHUNK_SIZE).put("chunkCount", chunks).also {
                    ensureCurrent(isCurrent)
                    check(recipientPrefs.edit().putString(manifestKey, it.toString()).commit()) { "Could not persist the phone transfer manifest." }
                    check(recipientPrefs.getString(manifestKey, null) == it.toString()) { "Phone transfer manifest readback failed." }
                }
        }
        val recipient = manifest.getString("macDeviceId")
        val serverManifest = api.createPhoneTransfer(manifest)
        val received = serverManifest.optJSONArray("receivedChunks")?.let { array ->
            (0 until array.length()).map { array.getInt(it) }.toSet()
        } ?: emptySet()
        ensureCurrent(isCurrent)
        if (state != "uploading" && !store.setTransferState(current.id, "uploading")) error("Could not save upload state.")
        RandomAccessFile(audio, "r").use { input ->
            for (index in 0 until chunks) {
                ensureCurrent(isCurrent)
                if (store.find(current.id)?.trashedAtMs != null) return
                if (index in received) continue
                val length = minOf(CHUNK_SIZE.toLong(), audio.length() - index.toLong() * CHUNK_SIZE).toInt()
                val plain = ByteArray(length)
                input.seek(index.toLong() * CHUNK_SIZE); input.readFully(plain)
                val encrypted = PhoneAudioTransferCrypto.encryptChunk(plain, key, manifest, index)
                ensureCurrent(isCurrent)
                api.putPhoneTransferChunk(transferId, index, encrypted)
            }
        }
        ensureCurrent(isCurrent)
        api.completePhoneTransfer(transferId)
        ensureCurrent(isCurrent)
        check(store.setTransferState(current.id, "uploaded")) { "Could not save upload state." }
        val receipt = runCatching { api.phoneTransferReceipt(transferId) }.getOrElse { error("Mac transcript receipt is not available yet.") }
        val transcriptHash = receipt.optString("transcriptSHA256")
        if (!verifyReceipt(receipt, key, transferId, current, api.currentWorkspaceId() ?: return, api.currentDeviceId() ?: return,
                recipient, audioHash, audio.length(), chunks)) error("Mac transcript receipt did not validate.")
        val receiptJson = receipt.toString()
        ensureCurrent(isCurrent)
        check(store.setTransferState(current.id, "receipt_received")) { "Could not persist the transcript receipt state." }
        ensureCurrent(isCurrent)
        if (store.purgeTransferredAudio(current.id, audioHash, transcriptHash, receiptJson)) {
            ensureCurrent(isCurrent)
            api.acknowledgePhoneTransfer(transferId, transcriptHash)
            ensureCurrent(isCurrent)
            check(store.setTransferState(current.id, "audio_deleted")) { "Could not save the acknowledged transfer state." }
        } else error("Phone audio was retained because receipt persistence or deletion did not complete.")
    }

    private fun ensureCurrent(isCurrent: () -> Boolean) {
        if (!isCurrent()) throw CancellationException("Phone audio transfer job was superseded.")
    }

    private fun verifyReceipt(r: JSONObject, key: ByteArray, transferId: String, m: MobileMeeting, workspaceId: String, originDeviceId: String,
                              macDeviceId: String, audioHash: String, length: Long, chunks: Int): Boolean {
        if (r.optInt("v") != 1 || r.optInt("protocolVersion") != 1 || r.optString("transferId") != transferId ||
            r.optString("workspaceId") != workspaceId ||
            !r.optBoolean("macAudioPurged", false) ||
            r.optString("deviceId") != originDeviceId || r.optString("macDeviceId") != macDeviceId ||
            r.optString("recordingId") != (m.sharedSessionId ?: m.id) || r.optString("audioSHA256") != audioHash ||
            r.optLong("plaintextLength") != length || r.optInt("chunkSize") != CHUNK_SIZE || r.optInt("chunkCount") != chunks ||
            !r.optString("transcriptSHA256").matches(Regex("[0-9a-f]{64}"))) return false
        if (!r.optBoolean("macAudioPurged", false)) return false
        val expected = PhoneAudioTransferCrypto.receiptMAC(key, r)
        val supplied = runCatching { Base64.decode(r.getString("mac"), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) }.getOrNull() ?: return false
        return MessageDigest.isEqual(expected, supplied)
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input -> val buf = ByteArray(64 * 1024); while (true) { val n = input.read(buf); if (n < 0) break; digest.update(buf, 0, n) } }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }


    private const val JOB_ID = 0x48414c
}
