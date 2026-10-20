package app.halle.companion

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import androidx.core.content.FileProvider
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

enum class MobileMeetingStatus { DRAFT, STARTING, RECORDING, RECORDED, INTERRUPTED, FAILED }

data class MobileMeeting(
    val id: String,
    val title: String,
    val projectName: String?,
    val createdAtMs: Long,
    val scheduledStartAtMs: Long?,
    val scheduledEndAtMs: Long?,
    val sourceEventKey: String?,
    val sharedSessionId: String?,
    val status: MobileMeetingStatus,
    val audioFileName: String?,
    val recordingStartedAtMs: Long?,
    val recordingStartedElapsedMs: Long?,
    val durationMs: Long,
    val error: String?,
)

/** Local-only meeting metadata and app-private recording files. */
class MobileMeetingStore(private val context: Context) {
    private var writableMetadata = true
    var loadError: String? = null
        private set
    fun list(): List<MobileMeeting> = synchronized(lock) { readAll().map { it.meeting } }

    fun createDraft(
        title: String,
        projectName: String? = null,
        sourceEventKey: String? = null,
        scheduledStartAtMs: Long? = null,
        scheduledEndAtMs: Long? = null,
        sharedSessionId: String? = null,
    ): MobileMeeting {
        val cleanTitle = title.trim().take(MAX_TITLE_LENGTH)
        require(cleanTitle.isNotEmpty()) { "A meeting title is required." }
        require(scheduledStartAtMs == null || scheduledEndAtMs == null || scheduledEndAtMs >= scheduledStartAtMs) {
            "The meeting end must be after its start."
        }
        val meeting = MobileMeeting(
            id = UUID.randomUUID().toString(), title = cleanTitle,
            projectName = cleanProject(projectName), createdAtMs = System.currentTimeMillis(),
            scheduledStartAtMs = scheduledStartAtMs, scheduledEndAtMs = scheduledEndAtMs,
            sourceEventKey = sourceEventKey, sharedSessionId = sharedSessionId,
            status = MobileMeetingStatus.DRAFT,
            audioFileName = null, recordingStartedAtMs = null, recordingStartedElapsedMs = null,
            durationMs = 0, error = null,
        )
        synchronized(lock) {
            val values = readAll().toMutableList()
            values.add(0, StoredMeeting(meeting, null))
            check(writeAll(values)) { "Could not save the meeting on this device." }
        }
        return meeting
    }

    fun find(id: String): MobileMeeting? = synchronized(lock) { readAll().firstOrNull { it.meeting.id == id }?.meeting }

    fun draftForSharedSession(sharedSessionId: String): MobileMeeting? = synchronized(lock) {
        readAll().firstOrNull {
            it.meeting.sharedSessionId == sharedSessionId && it.meeting.status == MobileMeetingStatus.DRAFT
        }?.meeting
    }

    /** Applies decrypted coordinator project values without touching meeting or recording state. */
    fun reconcileSharedProjects(projectsBySessionId: Map<String, String?>): Boolean = synchronized(lock) {
        if (projectsBySessionId.isEmpty()) return@synchronized true
        val values = readAll().toMutableList()
        var changed = false
        for (index in values.indices) {
            val stored = values[index]
            val sessionId = stored.meeting.sharedSessionId ?: continue
            if (!projectsBySessionId.containsKey(sessionId)) continue
            val projectName = cleanProject(projectsBySessionId[sessionId])
            if (stored.meeting.projectName != projectName) {
                values[index] = stored.copy(meeting = stored.meeting.copy(projectName = projectName))
                changed = true
            }
        }
        !changed || writeAll(values)
    }

    fun updateProject(id: String, projectName: String?): Boolean = update(id) { stored ->
        stored.copy(meeting = stored.meeting.copy(projectName = cleanProject(projectName)))
    }

    /** Binds one immutable coordinator session ID to a local meeting before publishing it. */
    fun setSharedSessionId(id: String, sharedSessionId: String): Boolean = synchronized(lock) {
        val values = readAll().toMutableList()
        val index = values.indexOfFirst { it.meeting.id == id }
        if (index < 0) return@synchronized false
        val current = values[index]
        val existing = current.meeting.sharedSessionId
        if (existing != null) return@synchronized existing == sharedSessionId
        values[index] = current.copy(meeting = current.meeting.copy(sharedSessionId = sharedSessionId))
        writeAll(values)
    }

    fun activeRecording(): MobileMeeting? = synchronized(lock) {
        readAll().firstOrNull {
            it.meeting.status == MobileMeetingStatus.STARTING || it.meeting.status == MobileMeetingStatus.RECORDING
        }?.meeting
    }

    /** Marks stale recording metadata after a process restart, keeping its partial file for recovery. */
    fun recoverInterrupted(): Int = synchronized(lock) {
        var changed = 0
        val values = readAll().map { stored ->
            if ((stored.meeting.status == MobileMeetingStatus.STARTING || stored.meeting.status == MobileMeetingStatus.RECORDING)
                && stored.ownerToken != processToken) {
                changed++
                stored.copy(meeting = stored.meeting.copy(
                    status = MobileMeetingStatus.INTERRUPTED,
                    error = "Recording was interrupted. The audio file may be incomplete.",
                ), ownerToken = null)
            } else stored
        }
        if (changed > 0) writeAll(values)
        changed
    }

    fun recordingElapsedMs(id: String): Long? = synchronized(lock) {
        val meeting = readAll().firstOrNull { it.meeting.id == id }?.meeting ?: return@synchronized null
        val began = meeting.recordingStartedElapsedMs ?: return@synchronized null
        if (meeting.status != MobileMeetingStatus.RECORDING) return@synchronized null
        (SystemClock.elapsedRealtime() - began).coerceAtLeast(0)
    }

    /** Completed recordings only; callers should invoke this after a user playback action. */
    fun playbackUri(id: String): Uri? = mediaUri(id)

    /** Completed recordings only; callers should invoke this after a user playback action. */
    fun playIntent(id: String): Intent? = playbackUri(id)?.let { uri ->
        Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, AUDIO_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newUri(context.contentResolver, find(id)?.title, uri)
        }
    }

    /** Completed recordings only; callers should invoke this after a user share action. */
    fun shareIntent(id: String): Intent? = playbackUri(id)?.let { uri ->
        Intent(Intent.ACTION_SEND).apply {
            type = AUDIO_MIME
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newUri(context.contentResolver, find(id)?.title, uri)
        }
    }

    /** Shares an interrupted recorder's raw partial file without claiming it is playable audio. */
    fun sharePartialFileIntent(id: String): Intent? {
        val meeting = find(id) ?: return null
        if (meeting.status != MobileMeetingStatus.INTERRUPTED || meeting.audioFileName != "$id.m4a.partial") return null
        val file = File(recordingDirectory(), "$id.m4a.partial")
        if (!file.isFile || file.length() <= 0L) return null
        val uri = runCatching {
            FileProvider.getUriForFile(context, "${context.packageName}.recordings", file)
        }.getOrNull() ?: return null
        return Intent(Intent.ACTION_SEND).apply {
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newUri(context.contentResolver, "${meeting.title} · partial recording file", uri)
        }
    }

    internal fun claimRecording(id: String): File? = synchronized(lock) {
        val values = readAll().toMutableList()
        val index = values.indexOfFirst { it.meeting.id == id }
        if (index < 0) return@synchronized null
        val current = values[index]
        if (current.meeting.status != MobileMeetingStatus.DRAFT) return@synchronized null
        if (values.any {
                it.meeting.status == MobileMeetingStatus.STARTING || it.meeting.status == MobileMeetingStatus.RECORDING
            }) return@synchronized null
        val directory = recordingDirectory()
        if (!directory.exists() && !directory.mkdirs()) return@synchronized null
        val partialName = "$id.m4a.partial"
        val partial = File(directory, partialName)
        if (partial.exists() && !partial.delete()) return@synchronized null
        values[index] = current.copy(meeting = current.meeting.copy(
            status = MobileMeetingStatus.STARTING,
            audioFileName = partialName,
            recordingStartedAtMs = System.currentTimeMillis(),
            recordingStartedElapsedMs = SystemClock.elapsedRealtime(),
            durationMs = 0,
            error = null,
        ), ownerToken = processToken)
        if (!writeAll(values)) {
            partial.delete()
            return@synchronized null
        }
        partial
    }

    internal fun markRecordingStarted(id: String): Boolean = update(id) { stored ->
        if (stored.meeting.status != MobileMeetingStatus.STARTING || stored.ownerToken != processToken) stored
        else stored.copy(meeting = stored.meeting.copy(status = MobileMeetingStatus.RECORDING))
    }

    internal fun completeRecording(id: String, partial: File, durationMs: Long): Boolean = synchronized(lock) {
        val finalName = "$id.m4a"
        val finalFile = File(recordingDirectory(), finalName)
        if (!partial.isFile || partial.length() <= 0L || !partial.renameTo(finalFile)) return@synchronized false
        val updated = updateLocked(id) { stored ->
            if ((stored.meeting.status != MobileMeetingStatus.RECORDING && stored.meeting.status != MobileMeetingStatus.STARTING)
                || stored.ownerToken != processToken) stored
            else stored.copy(meeting = stored.meeting.copy(
                status = MobileMeetingStatus.RECORDED,
                audioFileName = finalName,
                durationMs = durationMs.coerceAtLeast(0),
                recordingStartedElapsedMs = null,
                error = null,
            ), ownerToken = null)
        }
        if (!updated) finalFile.renameTo(partial)
        updated
    }

    internal fun interruptRecording(id: String, error: String, durationMs: Long = 0): Boolean = update(id) { stored ->
        if ((stored.meeting.status != MobileMeetingStatus.RECORDING && stored.meeting.status != MobileMeetingStatus.STARTING)
            || stored.ownerToken != processToken) stored
        else stored.copy(meeting = stored.meeting.copy(
            status = MobileMeetingStatus.INTERRUPTED,
            durationMs = durationMs.coerceAtLeast(0),
            error = error.take(MAX_ERROR_LENGTH),
        ), ownerToken = null)
    }

    internal fun finalizeInterruptedRecording(id: String, partial: File, error: String, durationMs: Long): Boolean = synchronized(lock) {
        val finalName = "$id.m4a"
        val finalFile = File(recordingDirectory(), finalName)
        if (!partial.isFile || partial.length() <= 0L || !partial.renameTo(finalFile)) return@synchronized false
        val updated = updateLocked(id) { stored ->
            if ((stored.meeting.status != MobileMeetingStatus.RECORDING && stored.meeting.status != MobileMeetingStatus.STARTING)
                || stored.ownerToken != processToken) stored
            else stored.copy(meeting = stored.meeting.copy(
                status = MobileMeetingStatus.INTERRUPTED,
                audioFileName = finalName,
                durationMs = durationMs.coerceAtLeast(0),
                error = error.take(MAX_ERROR_LENGTH),
            ), ownerToken = null)
        }
        if (!updated) finalFile.renameTo(partial)
        updated
    }

    internal fun failRecording(id: String, error: String): Boolean = update(id) { stored ->
        if ((stored.meeting.status != MobileMeetingStatus.RECORDING && stored.meeting.status != MobileMeetingStatus.STARTING)
            || stored.ownerToken != processToken) stored
        else stored.copy(meeting = stored.meeting.copy(
            status = MobileMeetingStatus.FAILED,
            error = error.take(MAX_ERROR_LENGTH),
        ), ownerToken = null)
    }

    internal fun returnUnstartedRecordingToDraft(id: String, output: File, error: String): Boolean = synchronized(lock) {
        val updated = updateLocked(id) { stored ->
            if ((stored.meeting.status != MobileMeetingStatus.RECORDING && stored.meeting.status != MobileMeetingStatus.STARTING)
                || stored.ownerToken != processToken) stored
            else stored.copy(meeting = stored.meeting.copy(
                status = MobileMeetingStatus.DRAFT,
                audioFileName = null,
                recordingStartedAtMs = null,
                recordingStartedElapsedMs = null,
                error = error.take(MAX_ERROR_LENGTH),
            ), ownerToken = null)
        }
        if (updated) output.delete()
        updated
    }

    private fun mediaUri(id: String): Uri? {
        val meeting = find(id) ?: return null
        if (meeting.status != MobileMeetingStatus.RECORDED && meeting.status != MobileMeetingStatus.INTERRUPTED) return null
        val name = meeting.audioFileName ?: return null
        if (name != "$id.m4a") return null
        val file = File(recordingDirectory(), name)
        if (!file.isFile) return null
        val uri = runCatching { FileProvider.getUriForFile(context, "${context.packageName}.recordings", file) }.getOrNull() ?: return null
        return uri
    }

    private fun recordingDirectory() = File(context.filesDir, RECORDINGS_DIRECTORY)

    private fun update(id: String, transform: (StoredMeeting) -> StoredMeeting): Boolean = synchronized(lock) {
        updateLocked(id, transform)
    }

    private fun updateLocked(id: String, transform: (StoredMeeting) -> StoredMeeting): Boolean {
        val values = readAll().toMutableList()
        val index = values.indexOfFirst { it.meeting.id == id }
        if (index < 0) return false
        val updated = transform(values[index])
        if (updated == values[index]) return false
        values[index] = updated
        return writeAll(values)
    }

    private fun readAll(): List<StoredMeeting> {
        writableMetadata = true
        loadError = null
        val raw = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY_MEETINGS, null) ?: return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val json = array.optJSONObject(index)
                    if (json == null) { markMetadataUnreadable(); continue }
                    val status = runCatching { MobileMeetingStatus.valueOf(json.getString("status")) }.getOrNull()
                    val id = json.optString("id").takeIf { value ->
                        runCatching { UUID.fromString(value).toString() == value.lowercase() }.getOrDefault(false)
                    }
                    if (status == null || id == null) { markMetadataUnreadable(); continue }
                    add(StoredMeeting(MobileMeeting(
                        id = id, title = json.optString("title"), projectName = json.optNullableString("projectName"),
                        createdAtMs = json.optLong("createdAtMs"), scheduledStartAtMs = json.optNullableLong("scheduledStartAtMs"),
                        scheduledEndAtMs = json.optNullableLong("scheduledEndAtMs"), sourceEventKey = json.optNullableString("sourceEventKey"),
                        sharedSessionId = json.optNullableString("sharedSessionId"),
                        status = status, audioFileName = json.optNullableString("audioFileName"),
                        recordingStartedAtMs = json.optNullableLong("recordingStartedAtMs"),
                        recordingStartedElapsedMs = json.optNullableLong("recordingStartedElapsedMs"),
                        durationMs = json.optLong("durationMs").coerceAtLeast(0), error = json.optNullableString("error"),
                    ), json.optNullableString("ownerToken")))
                }
            }
        }.getOrElse { markMetadataUnreadable(); emptyList() }
    }

    private fun markMetadataUnreadable() {
        writableMetadata = false
        loadError = "Some saved meeting metadata could not be read. It has been preserved; new changes are paused to protect your recordings."
    }

    private fun writeAll(values: List<StoredMeeting>): Boolean {
        if (!writableMetadata) return false
        val array = JSONArray()
        values.forEach { stored ->
            val m = stored.meeting
            array.put(JSONObject().apply {
                put("id", m.id); put("title", m.title); putNullable("projectName", m.projectName)
                put("createdAtMs", m.createdAtMs); putNullable("scheduledStartAtMs", m.scheduledStartAtMs)
                putNullable("scheduledEndAtMs", m.scheduledEndAtMs); putNullable("sourceEventKey", m.sourceEventKey)
                putNullable("sharedSessionId", m.sharedSessionId)
                put("status", m.status.name); putNullable("audioFileName", m.audioFileName)
                putNullable("recordingStartedAtMs", m.recordingStartedAtMs)
                putNullable("recordingStartedElapsedMs", m.recordingStartedElapsedMs)
                put("durationMs", m.durationMs); putNullable("error", m.error)
                putNullable("ownerToken", stored.ownerToken)
            })
        }
        return context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
            .putString(KEY_MEETINGS, array.toString()).commit()
    }

    private data class StoredMeeting(val meeting: MobileMeeting, val ownerToken: String?)

    private fun JSONObject.optNullableString(key: String): String? = if (isNull(key) || !has(key)) null else optString(key).takeIf(String::isNotBlank)
    private fun JSONObject.optNullableLong(key: String): Long? = if (isNull(key) || !has(key)) null else optLong(key)
    private fun JSONObject.putNullable(key: String, value: Any?) { put(key, value ?: JSONObject.NULL) }
    private fun cleanProject(value: String?): String? = value?.trim()?.take(MAX_PROJECT_LENGTH)?.takeIf(String::isNotEmpty)

    companion object {
        const val RECORDINGS_DIRECTORY = "recordings"
        const val AUDIO_MIME = "audio/mp4"
        private const val PREFERENCES = "mobile-meetings"
        private const val KEY_MEETINGS = "meetings"
        private const val MAX_TITLE_LENGTH = 160
        private const val MAX_PROJECT_LENGTH = 80
        private const val MAX_ERROR_LENGTH = 240
        private val lock = Any()
        internal val processToken: String = UUID.randomUUID().toString()
    }
}
