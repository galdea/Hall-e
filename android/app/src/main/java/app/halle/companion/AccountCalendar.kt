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

internal class AccountCalendar(context: Context, val session: AccountSession) {
    val media = MobileMeetingStore(context, session.scope)
    private val prefs = context.getSharedPreferences("private-calendar-" + session.scope, Context.MODE_PRIVATE)
    private fun objectFor(key: String) = prefs.getString(key, null)?.let(::JSONObject)
    private fun save(key: String, value: JSONObject?) {
        check(prefs.edit().putString(key, value?.toString()).commit()) { "Phone storage is unavailable." }
    }
    private fun keys(prefix: String) = prefs.all.keys.filter { it.startsWith(prefix) }.sorted()
    fun cached() = JSONArray(prefs.getString("snapshot", "[]")).objects()
    fun pending(id: String) = objectFor("edit-$id")
    fun recordings(id: String) = media.list().filter { it.sourceEventKey == id }
    fun upload(id: String) = objectFor("audio-$id")
    fun discard(id: String) { save("edit-$id", null) }
    fun stage(id: String, title: String, start: Instant, end: Instant, base: Int, deleting: Boolean) {
        meetingPath(id)
        require(title.isNotBlank() && title.trim().length <= 512 && end > start)
        check(pending(id) == null) { "Resolve the pending change first." }
        save("edit-$id", JSONObject().put("title", title.trim()).put("startAt", start.toString()).put("endAt", end.toString())
            .put("deleted", deleting).put("baseRevision", base).put("mutationId", UUID.randomUUID().toString()))
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

    // One sync runs per process. The caller supplies the live-session check for every outbound request.
    fun sync(request: (String, String, JSONObject?, ByteArray?) -> JSONObject) {
        media.recoverInterrupted()
        var sent = false
        for (id in mutationIds()) {
            val pending = pending(id) ?: continue
            if (pending.has("problem")) continue
            try {
                val accepted = request(meetingPath(id), "PUT", pending, null).getJSONObject("meeting")
                val previous = cached()
                if (!accepted.optBoolean("deleted")) {
                    val old = previous.firstOrNull { it.getString("id") == id }
                    old?.optJSONArray("recordings")?.let { accepted.put("recordings", it) }
                }
                val cached = previous.filter { it.getString("id") != id } + accepted
                // Persist the accepted revision and clear its outbox entry in one transaction.
                check(prefs.edit().putString("snapshot", JSONArray(cached).toString()).remove("version").remove("edit-$id").commit())
                sent = true
            } catch (error: AccountHttpError) {
                if (!permanent(error.status)) throw error
                save("edit-$id", pending.put("problem", error.status))
            }
        }
        for (key in keys("audio-")) {
            val id = key.removePrefix("audio-")
            val state = upload(id) ?: continue
            if (state.has("problem") || pending(state.getString("meeting")) != null) continue
            val file = media.completedAudio(id) ?: continue
            try {
                sendAccountRecording(id, state, file, request) { save(key, state) }
                check(prefs.edit().remove(key).remove("version").commit())
                sent = true
            } catch (error: AccountHttpError) {
                if (!permanent(error.status)) throw error
                save(key, state.put("problem", error.status))
            }
        }
        val prior = if (sent) null else prefs.getString("version", null)
        val path = snapshotPath(prior)
        val reply = request(path, "GET", null, null)
        if (reply.optBoolean("unchanged") && path != "/meetings" && reply.optString("version") == prior) return
        val list = reply.getJSONArray("meetings")
        val version = reply.optNullableString("version")?.takeIf { it.matches(versionFormat) }
        check(prefs.edit().putString("snapshot", list.toString()).putString("version", version).commit())
    }

    private fun permanent(status: Int) = status in 400..499 && status !in listOf(401, 408, 425, 429)
}

private val versionFormat = Regex("[0-9a-f]{32}")
internal fun snapshotPath(version: String?) = if (version != null && version.matches(versionFormat))
    "/meetings?since=$version" else "/meetings"

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
    fun transferAndComplete() {
        var index = state.getInt("nextPart")
        RandomAccessFile(file, "r").use { input ->
            input.seek(index.toLong() * partSize)
            while (input.filePointer < size) {
                val bytes = ByteArray(minOf(size - input.filePointer, partSize.toLong()).toInt())
                input.readFully(bytes)
                request("$path/parts/$index", "PUT", null, bytes)
                index++
                state.put("nextPart", index)
                checkpoint()
            }
        }
        request("$path/complete", "POST", JSONObject(), null)
    }
    val resumed = state.getInt("nextPart") > 0
    try { transferAndComplete() } catch (e: AccountHttpError) {
        // Inactive uploads can expire while the phone is offline. Recreate just the missing manifest's bytes.
        if (!resumed || e.status != 409 || e.reason != "missing_parts") throw e
        state.put("nextPart", 0)
        checkpoint()
        transferAndComplete()
    }
}
