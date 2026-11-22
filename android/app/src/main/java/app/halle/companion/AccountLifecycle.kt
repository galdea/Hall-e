package app.halle.companion

import android.content.Context
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.UUID

/** Optional server capabilities reported by `GET /auth/session`. A missing or non-boolean flag means false. */
internal data class AccountFeatures(val accountDeletion: Boolean, val lazyTranscripts: Boolean) {
    fun json(): JSONObject = JSONObject().put("accountDeletion", accountDeletion).put("lazyTranscripts", lazyTranscripts)
    companion object {
        val NONE = AccountFeatures(accountDeletion = false, lazyTranscripts = false)
        fun from(reply: JSONObject?): AccountFeatures {
            val features = reply?.optJSONObject("features") ?: return NONE
            return AccountFeatures(features.opt("accountDeletion") == true, features.opt("lazyTranscripts") == true)
        }
    }
}

internal const val ACCOUNT_DELETION_CONFIRMATION = "DELETE"
internal fun isAccountDeletionConfirmed(typed: String) = typed.trim() == ACCOUNT_DELETION_CONFIRMATION

/** The service deleted the account, but this phone could not remove all of that account's cached data. */
internal class LocalWipeIncomplete(cause: Throwable?) : IllegalStateException("Local account data was not fully removed.", cause)

/** A transcript sent inside the agenda (old servers, or a client that did not ask for lazy transcripts). */
internal fun inlineTranscript(recording: JSONObject): String? = recording.optNullableString("transcript")

/** The agenda says a transcript exists but carries only metadata; it is fetched per recording on open. */
internal fun hasRemoteTranscript(recording: JSONObject): Boolean = inlineTranscript(recording) == null &&
    (recording.opt("transcriptAvailable") == true || recording.opt("transcriptStoredSeparately") == true)

internal fun transcriptBytes(recording: JSONObject): Long? =
    if (!recording.has("transcriptBytes") || recording.isNull("transcriptBytes")) null
    else (recording.opt("transcriptBytes") as? Number)?.toLong()?.takeIf { it >= 0 }

// The service stores transcripts of up to 8 MiB separately; anything larger is not a transcript reply.
internal const val MAX_TRANSCRIPT_BYTES = 8 * 1024 * 1024

/** Reads a `200 text/plain; charset=utf-8` transcript body, refusing other media types and oversize bodies. */
internal fun transcriptText(contentType: String?, input: InputStream): String {
    val media = contentType?.substringBefore(';')?.trim()?.lowercase(java.util.Locale.ROOT)
    if (media != "text/plain") throw IOException("Unexpected transcript media type")
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (true) {
        val n = input.read(buffer)
        if (n < 0) break
        out.write(buffer, 0, n)
        if (out.size() > MAX_TRANSCRIPT_BYTES) throw IOException("Transcript is larger than expected")
    }
    return out.toString(Charsets.UTF_8.name())
}

/**
 * Per-account transcript copies in app-private, no-backup storage. Files are named only by recording UUID, and the
 * whole directory belongs to one account scope, like the account's audio directory.
 */
internal class AccountTranscriptCache(private val directory: File) {
    constructor(context: Context, scope: String) : this(File(context.noBackupFilesDir, "account-transcripts/" +
        scope.also { require(it.matches(Regex("[0-9a-f]{64}"))) }))

    private fun name(recordingId: String): String {
        val id = UUID.fromString(recordingId).toString()
        require(id.equals(recordingId, true))
        return id
    }

    /** Returns the cached text, or null when absent, unreadable or not the size the agenda announces. */
    fun read(recordingId: String, expectedBytes: Long? = null): String? = synchronized(lock) {
        val file = File(directory, name(recordingId) + ".txt")
        if (!file.isFile || (expectedBytes != null && file.length() != expectedBytes)) return@synchronized null
        runCatching { file.readText(Charsets.UTF_8) }.getOrNull()
    }

    /** Writes atomically, and only while [stillWanted] holds, so a concurrent eviction or wipe is never undone. */
    fun write(recordingId: String, text: String, stillWanted: () -> Boolean): Boolean = synchronized(lock) {
        val id = name(recordingId)
        if (!stillWanted()) return@synchronized false
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Transcript storage is unavailable")
        val partial = File(directory, "$id.partial")
        partial.writeText(text, Charsets.UTF_8)
        if (!partial.renameTo(File(directory, "$id.txt"))) {
            partial.delete()
            throw IOException("Transcript storage is unavailable")
        }
        true
    }

    /** Removes every cached transcript whose recording is not in [recordingIds] (and any interrupted write). */
    fun retain(recordingIds: Set<String>) = synchronized(lock) {
        val keep = recordingIds.map { it.lowercase(java.util.Locale.ROOT) }.toSet()
        directory.listFiles()?.forEach { file ->
            if (!file.name.endsWith(".txt") || file.name.removeSuffix(".txt") !in keep) file.delete()
        }
    }

    fun clear(): Boolean = synchronized(lock) { !directory.exists() || directory.deleteRecursively() }

    companion object { private val lock = Any() }
}
