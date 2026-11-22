package app.halle.companion

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.Executors

/** One stored metadata document: the JSON array a [MobileMeetingStore] keeps. Writing null removes it. */
internal interface RecordingMetadata {
    fun read(): String?
    fun write(value: String?): Boolean
}

internal data class RecordingMoveOutcome(val moved: Int, val deferred: Int, val complete: Boolean)

private val audioSuffixes = listOf(".m4a", ".m4a.partial")
private val activeStatuses = setOf(MobileMeetingStatus.STARTING.name, MobileMeetingStatus.RECORDING.name)

/** The personal ID used when a moved recording's own ID is already taken by a different personal recording. */
internal fun movedRecordingId(scope: String, id: String): String =
    UUID.nameUUIDFromBytes("account-recording:$scope:$id".toByteArray()).toString()

private fun parse(raw: String?): JSONArray? = if (raw == null) JSONArray() else runCatching { JSONArray(raw) }.getOrNull()
private fun JSONArray.entries() = (0 until length()).mapNotNull { optJSONObject(it) }
private fun JSONArray.without(id: String) = JSONArray().also { out ->
    for (i in 0 until length()) { val value = opt(i); if ((value as? JSONObject)?.optString("id") != id) out.put(value) }
}
private fun validId(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)

// The same recording, already appended by an earlier, interrupted move.
private fun sameRecording(personal: JSONObject, scoped: JSONObject) =
    personal.optLong("createdAtMs") == scoped.optLong("createdAtMs") && personal.optString("title") == scoped.optString("title")

private sealed interface MovePlan {
    object Gone : MovePlan
    object Deferred : MovePlan
    object Blocked : MovePlan
    object NoAudio : MovePlan
    object AlreadyMoved : MovePlan
    data class Move(val target: String, val files: List<Pair<File, File>>) : MovePlan
}

private fun plan(scope: String, id: String, scoped: JSONArray, personal: JSONArray, scopedDir: File, personalDir: File): MovePlan {
    val entry = scoped.entries().firstOrNull { it.optString("id") == id } ?: return MovePlan.Gone
    if (entry.optString("status") in activeStatuses) return MovePlan.Deferred
    val sources = audioSuffixes.map { File(scopedDir, id + it) to it }.filter { it.first.isFile }
    for (candidate in listOf(id, movedRecordingId(scope, id))) {
        val existing = personal.entries().firstOrNull { it.optString("id") == candidate }
        if (existing == null) return if (sources.isEmpty()) MovePlan.NoAudio
            else MovePlan.Move(candidate, sources.map { (file, suffix) -> file to File(personalDir, candidate + suffix) })
        if (sameRecording(existing, entry)) return MovePlan.AlreadyMoved
    }
    return MovePlan.Blocked
}

private fun movedEntry(entry: JSONObject, id: String, target: String): JSONObject = JSONObject(entry.toString()).apply {
    put("id", target)
    put("sourceEventKey", JSONObject.NULL) // The account meeting no longer exists.
    put("ownerToken", JSONObject.NULL)
    val audio = if (isNull("audioFileName")) null else optString("audioFileName")
    put("audioFileName", audioSuffixes.firstOrNull { audio == id + it }?.let { target + it } ?: JSONObject.NULL)
}

/** Hard-links when the filesystem allows it (no second copy of the audio), otherwise copies. */
internal fun linkOrCopy(source: File, target: File) {
    target.delete()
    try { Files.createLink(target.toPath(), source.toPath()) }
    catch (_: Exception) { Files.copy(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING) }
}

/**
 * Moves every finished recording of a deleted account's scoped store into the personal store, one recording at a time:
 * 1. place its audio under the personal directory (link or copy to a temporary name, then an atomic rename),
 * 2. append its metadata to the personal store, 3. remove it from the scoped store, 4. delete the scoped files.
 * An interruption leaves the scoped copy, the personal copy, or both — never neither — and a rerun finishes the job
 * without duplicating. A personal recording is never overwritten: a different one with the same ID makes the moved
 * copy use [movedRecordingId]. Recordings still in progress are deferred. Nothing is uploaded or sent.
 * Metadata reads and writes run inside [locked]; file transfers do not.
 */
internal fun moveScopedRecordings(
    scope: String,
    scoped: RecordingMetadata,
    personal: RecordingMetadata,
    scopedDir: File,
    personalDir: File,
    locked: (() -> Unit) -> Unit = { it() },
    transfer: (File, File) -> Unit = ::linkOrCopy,
): RecordingMoveOutcome {
    var ids = emptyList<String>()
    var readable = true
    locked {
        val entries = parse(scoped.read())
        if (entries == null) readable = false else ids = entries.entries().map { it.optString("id") }.filter(::validId)
    }
    if (!readable) return RecordingMoveOutcome(0, 0, complete = false)
    var moved = 0
    var deferred = 0
    for (id in ids) {
        var step: MovePlan = MovePlan.Gone
        locked {
            val scopedEntries = parse(scoped.read())
            val personalEntries = parse(personal.read())
            step = if (scopedEntries == null || personalEntries == null) MovePlan.Blocked
                else plan(scope, id, scopedEntries, personalEntries, scopedDir, personalDir)
        }
        when (val current = step) {
            MovePlan.Gone, MovePlan.Blocked -> continue
            MovePlan.Deferred -> { deferred++; continue }
            MovePlan.NoAudio, MovePlan.AlreadyMoved -> Unit
            is MovePlan.Move -> {
                if (!personalDir.isDirectory && !personalDir.mkdirs()) throw IOException("Recording storage is unavailable")
                for ((source, target) in current.files) {
                    val staging = File(target.parentFile, target.name + ".moving")
                    transfer(source, staging)
                    Files.move(staging.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
                    // rename(2) is a no-op when a rerun already linked the target to the same file; drop the extra name.
                    staging.delete()
                }
            }
        }
        var removed = false
        locked {
            val scopedEntries = parse(scoped.read()) ?: return@locked
            val entry = scopedEntries.entries().firstOrNull { it.optString("id") == id } ?: return@locked
            val current = step
            if (current is MovePlan.Move) {
                val personalEntries = parse(personal.read()) ?: return@locked
                val taken = personalEntries.entries().firstOrNull { it.optString("id") == current.target }
                if (taken == null) {
                    // Newest first, like a recording created on this phone.
                    val updated = JSONArray().put(movedEntry(entry, id, current.target))
                    for (i in 0 until personalEntries.length()) updated.put(personalEntries.opt(i))
                    check(personal.write(updated.toString())) { "Could not save the personal recording." }
                } else if (!sameRecording(taken, entry)) return@locked
                moved++
            }
            check(scoped.write(scopedEntries.without(id).toString())) { "Could not update the account recordings." }
            removed = true
        }
        if (removed) audioSuffixes.forEach { File(scopedDir, id + it).delete() }
    }
    var complete = false
    locked {
        val left = parse(scoped.read())
        if (left != null && left.length() == 0 && scoped.write(null)) complete = true
    }
    if (complete) complete = !scopedDir.exists() || scopedDir.deleteRecursively()
    return RecordingMoveOutcome(moved, deferred, complete)
}

/**
 * Account scopes whose recordings still have to move into the personal library after account deletion. A scope is
 * registered before the account's local data is wiped and leaves the list only once its scoped store is gone.
 */
internal object AccountRecordingMoves {
    private const val PREFERENCES = "account-recording-moves"
    private val executor = Executors.newSingleThreadExecutor()
    private val lock = Any()

    fun add(context: Context, scope: String) = synchronized(lock) {
        require(scope.matches(Regex("[0-9a-f]{64}")))
        check(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putBoolean(scope, true).commit())
    }

    private fun pending(context: Context) = synchronized(lock) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).all.keys.filter { it.matches(Regex("[0-9a-f]{64}")) }
    }

    /** Runs pending moves off the main thread; [moved] is called (on that thread) when any recording moved. */
    fun resumeAsync(context: Context, moved: () -> Unit = {}) {
        val app = context.applicationContext
        if (pending(app).isEmpty()) return
        executor.execute {
            var any = false
            for (scope in pending(app)) {
                val outcome = runCatching { MobileMeetingStore.moveAccountRecordings(app, scope) }.getOrNull() ?: continue
                any = any || outcome.moved > 0
                if (outcome.complete) synchronized(lock) {
                    app.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().remove(scope).commit()
                }
            }
            if (any) moved()
        }
    }
}
