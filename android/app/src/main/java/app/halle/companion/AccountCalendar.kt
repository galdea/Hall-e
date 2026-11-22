package app.halle.companion

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
internal fun meetingPath(id: String): String {
    require(UUID.fromString(id).toString().equals(id, true))
    return "/meetings/$id"
}

internal interface CalendarStorage {
    fun getString(key: String, default: String? = null): String?
    fun keys(prefix: String): List<String>
    fun commit(edits: Map<String, String?>): Boolean
}

private class PrefsCalendarStorage(context: Context, scope: String) : CalendarStorage {
    private val prefs = context.getSharedPreferences("private-calendar-$scope", Context.MODE_PRIVATE)
    override fun getString(key: String, default: String?): String? = prefs.getString(key, default)
    override fun keys(prefix: String): List<String> = prefs.all.keys.filter { it.startsWith(prefix) }.sorted()
    override fun commit(edits: Map<String, String?>): Boolean {
        val editor = prefs.edit()
        for ((k, v) in edits) {
            if (v == null) editor.remove(k) else editor.putString(k, v)
        }
        return editor.commit()
    }
}

internal class AccountCalendar internal constructor(
    val session: AccountSession,
    private val storage: CalendarStorage,
    private val mediaStore: MobileMeetingStore?,
    private val recoverAudio: () -> Unit = { mediaStore?.recoverInterrupted() },
    private val completedAudioFile: (String) -> File? = { mediaStore?.completedAudio(it) },
    private val transcripts: AccountTranscriptCache? = null,
) {
    constructor(context: Context, session: AccountSession) : this(
        session = session,
        storage = PrefsCalendarStorage(context, session.scope),
        mediaStore = MobileMeetingStore(context, session.scope),
        transcripts = AccountTranscriptCache(context, session.scope),
    )

    val media: MobileMeetingStore get() = requireNotNull(mediaStore)
    private fun objectFor(key: String) = storage.getString(key, null)?.let(::JSONObject)
    private fun save(key: String, value: JSONObject?) {
        check(storage.commit(mapOf(key to value?.toString()))) { "Phone storage is unavailable." }
    }
    private fun keys(prefix: String) = storage.keys(prefix)
    fun cached() = JSONArray(storage.getString("snapshot", "[]") ?: "[]").objects()
    fun pending(id: String) = objectFor("edit-$id")
    fun recordings(id: String) = media.list().filter { it.sourceEventKey == id }
    // A recording is orphaned only when the account confirms its meeting is gone. A meeting with any
    // pending change (including an unresolved conflict) or a calendar that has never been pulled is not.
    internal fun isOrphanedMeeting(meetingId: String): Boolean {
        if (pending(meetingId) != null || storage.getString("snapshot", null) == null) return false
        return cached().none { it.getString("id") == meetingId && !it.optBoolean("deleted") }
    }
    fun orphanedRecordings(): List<MobileMeeting> =
        media.list().filter { recording -> recording.sourceEventKey?.let(::isOrphanedMeeting) == true }
    fun deleteOrphanedRecording(recordingId: String) {
        discardUpload(recordingId)
        media.deleteRecording(recordingId)
    }
    fun upload(id: String) = objectFor("audio-$id")
    fun discard(id: String) { save("edit-$id", null) }
    fun retryUpload(recordingId: String) {
        val state = upload(recordingId) ?: return
        state.remove("problem")
        save("audio-$recordingId", state)
    }
    fun discardUpload(recordingId: String) { save("audio-$recordingId", null) }
    fun projects() = accountProjects(cached(), mutationIds().mapNotNull(::pending))
    fun retryProject(id: String) {
        val change = pending(id) ?: return
        check(change.optString("problem") == "unsupported_project")
        change.remove("problem")
        save("edit-$id", change)
    }
    fun reapply(id: String) {
        val local = pending(id) ?: throw IllegalStateException("No pending change.")
        check(local.has("problem")) { "Change is not in conflict." }
        val current = cached().firstOrNull { it.getString("id") == id && !it.optBoolean("deleted") }
            ?: throw IllegalStateException("Meeting no longer exists.")
        val revised = JSONObject(local.toString())
            .put("baseRevision", current.getInt("revision"))
            .put("mutationId", UUID.randomUUID().toString())
        revised.remove("problem")
        save("edit-$id", revised)
    }
    fun stage(id: String, title: String, start: Instant, end: Instant, base: Int, deleting: Boolean,
              project: ProjectChange? = null) {
        meetingPath(id)
        require(title.isNotBlank() && title.trim().length <= 512 && end > start)
        check(pending(id) == null) { "Resolve the pending change first." }
        val change = JSONObject().put("title", title.trim()).put("startAt", start.toString()).put("endAt", end.toString())
            .put("deleted", deleting).put("baseRevision", base).put("mutationId", UUID.randomUUID().toString())
        if (!deleting) {
            val previous = cached().firstOrNull { it.getString("id") == id }
            stageProject(change, project, AccountProject.read(previous?.optJSONObject("project")))
        }
        save("edit-$id", change)
    }
    fun visible(): List<JSONObject> {
        val meetings = cached().associateBy { it.getString("id") }.toMutableMap()
        for (key in keys("edit-")) {
            val id = key.removePrefix("edit-")
            val local = pending(id) ?: continue
            if (local.has("problem")) continue
            val old = meetings[id]
            meetings[id] = JSONObject(local.toString()).put("id", id).put("revision", local.getInt("baseRevision"))
                .put("recordings", old?.optJSONArray("recordings") ?: JSONArray())
                .put("project", pendingProject(local, old)?.json() ?: JSONObject.NULL)
        }
        // Keep pending deletes and conflicts accessible until reconciled.
        return meetings.values.filter { !it.optBoolean("deleted") || pending(it.getString("id")) != null }
            .sortedBy { Instant.parse(it.getString("startAt")) }
    }
    fun mutationIds() = keys("edit-").map { it.removePrefix("edit-") }
    fun enqueueAudio(meeting: String, recording: String, provider: String) {
        require(provider in setOf("deepgram", "speechmatics"))
        save("audio-$recording", JSONObject().put("meeting", meeting).put("provider", provider).put("nextPart", 0))
    }

    private fun pullSnapshot(request: (String, String, JSONObject?, ByteArray?) -> JSONObject, force: Boolean) {
        val prior = (if (force) null else storage.getString("version", null))?.takeIf { it.matches(versionFormat) }
        val reply = request(snapshotPath(prior), "GET", null, null)
        if (reply.optBoolean("unchanged") && prior != null && reply.optString("version") == prior) return
        val list = reply.getJSONArray("meetings")
        val version = reply.optNullableString("version")?.takeIf { it.matches(versionFormat) }
        check(storage.commit(mapOf("snapshot" to list.toString(), "version" to version)))
        evictTranscripts()
    }

    private fun remoteRecording(meetingId: String, recordingId: String): JSONObject? = cached()
        .firstOrNull { it.getString("id") == meetingId }?.optJSONArray("recordings")?.objects()
        ?.firstOrNull { it.optString("id").equals(recordingId, true) }

    private fun keepsTranscript(recording: JSONObject?) = recording != null && recording.opt("transcriptAvailable") != false

    // Cached transcripts follow the snapshot: a recording that left it, or reports no transcript, loses its copy.
    private fun evictTranscripts() {
        val listed = cached().flatMap { (it.optJSONArray("recordings") ?: JSONArray()).objects() }
            .filter(::keepsTranscript).map { it.optString("id") }.toSet()
        transcripts?.retain(listed)
    }

    /** The phone's copy of a lazily served transcript, when it matches the size the agenda announces. */
    fun cachedTranscript(recording: JSONObject): String? {
        if (!hasRemoteTranscript(recording)) return null
        val id = recording.optString("id")
        if (runCatching { UUID.fromString(id) }.isFailure) return null
        return transcripts?.read(id, transcriptBytes(recording))
    }

    /**
     * Returns a recording's transcript from the phone cache or `GET meetings/:id/recordings/:rid/transcript`, and null
     * when the service has none (404). The copy is kept only while the snapshot still lists the recording.
     */
    fun loadTranscript(meetingId: String, recordingId: String, fetch: (String) -> String): String? {
        val recording = UUID.fromString(recordingId).toString()
        val path = meetingPath(meetingId) + "/recordings/" + recording + "/transcript"
        remoteRecording(meetingId, recording)?.let(::cachedTranscript)?.let { return it }
        val text = try { fetch(path) } catch (error: AccountHttpError) {
            if (error.status == 404) return null
            throw error
        }
        transcripts?.write(recording, text) { keepsTranscript(remoteRecording(meetingId, recording)) }
        return text
    }

    private val featureSession: String get() =
        MessageDigest.getInstance("SHA-256").digest(("features\n" + session.token).toByteArray()).hex()

    /** Capabilities cached for this signed-in session; none until [refreshFeatures] has succeeded once. */
    fun features(): AccountFeatures = objectFor("features")?.takeIf { it.optString("session") == featureSession }
        ?.let(AccountFeatures::from) ?: AccountFeatures.NONE

    /** Reads `features` from `GET /auth/session` once per signed-in session. */
    fun refreshFeatures(request: (String, String, JSONObject?, ByteArray?) -> JSONObject): AccountFeatures {
        objectFor("features")?.takeIf { it.optString("session") == featureSession }?.let { return AccountFeatures.from(it) }
        val reply = request("/auth/session", "GET", null, null)
        check(reply.optNullableString("userId")?.let { it == session.userId } != false) { "Session belongs to another account." }
        val features = AccountFeatures.from(reply)
        save("features", JSONObject().put("session", featureSession).put("features", features.json()))
        return features
    }

    /**
     * Deletes the account on the service (`POST account/delete`). Only after `202 {"status": "deleting"}` does it
     * [keepRecordings] (hand the phone recordings to the personal library), remove this account's snapshot, version,
     * outbox, capabilities and cached transcripts, and [forgetSession]. Any error before that changes nothing on the phone.
     */
    fun deleteAccount(request: (String, String, JSONObject?, ByteArray?) -> JSONObject,
                      keepRecordings: () -> Unit = {}, forgetSession: () -> Unit) {
        val reply = request("/account/delete", "POST", JSONObject().put("confirmation", ACCOUNT_DELETION_CONFIRMATION), null)
        check(reply.optString("status") == "deleting") { "Unexpected account deletion reply." }
        var failure: Exception? = null
        try {
            try { keepRecordings() } catch (error: Exception) { failure = error }
            try { forgetAccount() } catch (error: Exception) { failure = failure ?: error }
        } finally { forgetSession() }
        failure?.let { throw LocalWipeIncomplete(it) }
    }

    /** Removes everything this class stores for the account. Recordings in [MobileMeetingStore] are not touched. */
    internal fun forgetAccount() {
        val stored = storage.commit(keys("").associateWith { null })
        val cleared = transcripts?.clear() ?: true
        check(stored && cleared) { "Phone storage is unavailable." }
    }

    private fun isRemotelyDeleted(meetingId: String): Boolean =
        pending(meetingId) == null && cached().any { it.getString("id") == meetingId && it.optBoolean("deleted") }

    // One sync runs per process. The caller supplies the live-session check for every outbound request.
    fun sync(request: (String, String, JSONObject?, ByteArray?) -> JSONObject) {
        recoverAudio()
        var sent = false
        for (id in mutationIds()) {
            val pending = pending(id) ?: continue
            if (pending.has("problem")) continue
            try {
                val accepted = request(meetingPath(id), "PUT", meetingRequest(pending), null).getJSONObject("meeting")
                val previous = cached()
                if (!accepted.optBoolean("deleted")) {
                    val old = previous.firstOrNull { it.getString("id") == id }
                    old?.optJSONArray("recordings")?.let { accepted.put("recordings", it) }
                }
                val cached = previous.filter { it.getString("id") != id } + accepted
                // Persist the accepted revision and clear its outbox entry in one transaction.
                val edits = mutableMapOf<String, String?>("snapshot" to JSONArray(cached).toString(), "version" to null)
                if (projectSelectionAccepted(pending, accepted)) edits["edit-$id"] = null
                else {
                    // Older servers can acknowledge the meeting while ignoring an explicit assignment.
                    if (accepted.optBoolean("deleted") || accepted.getInt("revision") != pending.getInt("baseRevision") + 1) {
                        // A replay can return a newer revision already changed on the other device.
                        pending.put("problem", 409)
                    } else {
                        pending.put("title", accepted.getString("title")).put("startAt", accepted.getString("startAt"))
                            .put("endAt", accepted.getString("endAt")).put("baseRevision", accepted.getInt("revision"))
                            .put("mutationId", UUID.randomUUID().toString()).put("problem", "unsupported_project")
                    }
                    edits["edit-$id"] = pending.toString()
                }
                check(storage.commit(edits))
                sent = true
            } catch (error: AccountHttpError) {
                if (!permanent(error.status)) throw error
                save("edit-$id", pending.put("problem", error.status))
            }
        }
        val audioKeys = keys("audio-")
        var pulled = false
        if (audioKeys.any { upload(it.removePrefix("audio-"))?.has("problem") != true }) {
            pullSnapshot(request, force = sent)
            pulled = true
        }
        var uploadedAudio = false
        for (key in audioKeys) {
            val id = key.removePrefix("audio-")
            val state = upload(id) ?: continue
            val meetingId = state.getString("meeting")
            val edit = pending(meetingId)
            if (state.has("problem") || (edit != null && edit.optString("problem") != "unsupported_project")) continue
            if (isRemotelyDeleted(meetingId)) {
                discardUpload(id)
                continue
            }
            val file = completedAudioFile(id) ?: continue
            try {
                sendAccountRecording(id, state, file, request) { save(key, state) }
                check(storage.commit(mapOf(key to null, "version" to null)))
                uploadedAudio = true
            } catch (error: AccountHttpError) {
                if (error.status == 404) {
                    pullSnapshot(request, force = true)
                    pulled = true
                    if (isRemotelyDeleted(meetingId)) {
                        discardUpload(id)
                        continue
                    }
                }
                if (!permanent(error.status)) throw error
                save(key, state.put("problem", error.status))
            }
        }
        if (!pulled || uploadedAudio) {
            pullSnapshot(request, force = sent || uploadedAudio)
        }
    }

    /**
     * Ends an account recording the service stopped on (`review` or `failed`). The server answers 204, also on a
     * retry, and `409 recording_active` when the recording is not in a discardable state; that returns false.
     */
    fun discardRemoteRecording(meetingId: String, recordingId: String,
                               request: (String, String, JSONObject?, ByteArray?) -> JSONObject): Boolean {
        val recording = UUID.fromString(recordingId).toString()
        try {
            request(meetingPath(meetingId) + "/recordings/" + recording, "DELETE", null, null)
        } catch (error: AccountHttpError) {
            if (error.status == 409 && error.reason == "recording_active") return false
            throw error
        }
        // Hide it until the next full pull confirms the disposal.
        val snapshot = cached().map { row ->
            if (row.getString("id") != meetingId) row
            else row.put("recordings", JSONArray((row.optJSONArray("recordings") ?: JSONArray()).objects()
                .filter { !it.optString("id").equals(recording, true) }))
        }
        check(storage.commit(mapOf("snapshot" to JSONArray(snapshot).toString(), "version" to null)))
        evictTranscripts()
        return true
    }

    private fun permanent(status: Int) = status in 400..499 && status !in listOf(401, 408, 425, 429)
}

internal fun isDiscardableRecording(recording: JSONObject) = recording.optString("status") in setOf("review", "failed")

private val versionFormat = Regex("[0-9a-f]{32}")
// Recordings carry metadata only; servers that predate lazy transcripts ignore the parameter and send them inline.
internal fun snapshotPath(version: String?) = if (version != null && version.matches(versionFormat))
    "/meetings?transcripts=lazy&since=$version" else "/meetings?transcripts=lazy"

internal fun sendAccountRecording(id: String, state: JSONObject, file: File,
                                 request: (String, String, JSONObject?, ByteArray?) -> JSONObject,
                                 checkpoint: () -> Unit) {
    val path = meetingPath(state.getString("meeting")) + "/recordings/" + UUID.fromString(id)
    val size = file.length()
    if (size !in 1..256L*1024*1024) throw AccountHttpError(413, null)
    val hash = state.optNullableString("sha256") ?: file.inputStream().buffered().use { stream ->
        val digest = MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(64*1024)
        while (true) {
            val n = stream.read(buf)
            if (n < 0) break
            digest.update(buf, 0, n)
        }
        digest.digest().hex()
    }.also { state.put("sha256", it); checkpoint() }
    val provider = state.getString("provider")
    val manifest = JSONObject().put("size", size).put("sha256", hash).put("mimeType", "audio/mp4")
        .put("consent", true).put("provider", provider)
    if (provider == "speechmatics") manifest.put("region", "eu1")
    val remote = request(path, "PUT", manifest, null)
    if (remote.getString("status") != "uploading") return
    val partSize = remote.getInt("partSize")
    require(partSize in 1..8*1024*1024)
    val partCount = ((size + partSize - 1) / partSize).toInt()
    fun transfer(from: Int, until: Int, sent: (Int) -> Unit) {
        RandomAccessFile(file, "r").use { input ->
            for (index in from until until) {
                input.seek(index.toLong() * partSize)
                val bytes = ByteArray(minOf(size - input.filePointer, partSize.toLong()).toInt())
                input.readFully(bytes)
                request("$path/parts/$index", "PUT", null, bytes)
                sent(index + 1)
            }
        }
    }
    fun complete() { request("$path/complete", "POST", JSONObject(), null) }
    val resumeFrom = state.getInt("nextPart").coerceIn(0, partCount)
    transfer(resumeFrom, partCount) { state.put("nextPart", it); checkpoint() }
    try { complete() } catch (e: AccountHttpError) {
        if (e.status != 409 || e.reason != "missing_parts") throw e
        // The server reports only that parts are missing, and marks them unstored, so re-send once:
        // - resumed upload: it may have expired while the phone was offline, and the parts at or above resumeFrom
        //   were just sent to the recreated upload, so only the earlier parts are replayed;
        // - fresh upload (or nothing earlier to replay): storage lost a part just sent, so every part is re-sent.
        // nextPart stays at partCount: an interrupted replay restarts from part 0 in the next cycle.
        transfer(0, if (resumeFrom == 0) partCount else resumeFrom) {}
        complete()
    }
}
