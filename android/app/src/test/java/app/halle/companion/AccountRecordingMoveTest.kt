package app.halle.companion

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.util.UUID

class AccountRecordingMoveTest {
    @get:Rule val tmp = TemporaryFolder()
    private val scope = "ab".repeat(32)
    private val scopedDir by lazy { File(tmp.root, "no_backup/account-audio/$scope").apply { mkdirs() } }
    private val personalDir by lazy { File(tmp.root, "files/recordings") }
    private var inLock = false

    private inner class Metadata(var value: String?) : RecordingMetadata {
        var failWrites = false
        override fun read(): String? { assertTrue("metadata read outside the store lock", inLock); return value }
        override fun write(value: String?): Boolean {
            assertTrue("metadata write outside the store lock", inLock)
            if (failWrites) return false
            this.value = value
            return true
        }
        fun entries() = value?.let { raw -> JSONArray(raw).let { a -> (0 until a.length()).map { a.getJSONObject(it) } } }.orEmpty()
        fun entry(id: String) = entries().singleOrNull { it.getString("id") == id }
    }

    private fun entry(id: String, status: MobileMeetingStatus = MobileMeetingStatus.RECORDED, audio: String? = "$id.m4a",
                      title: String = "Synthetic account recording", createdAtMs: Long = 1_700_000_000_000) =
        JSONObject().put("id", id).put("title", title).put("projectName", JSONObject.NULL).put("createdAtMs", createdAtMs)
            .put("scheduledStartAtMs", JSONObject.NULL).put("scheduledEndAtMs", JSONObject.NULL)
            .put("sourceEventKey", UUID.randomUUID().toString()).put("sharedSessionId", JSONObject.NULL)
            .put("status", status.name).put("audioFileName", audio ?: JSONObject.NULL)
            .put("recordingStartedAtMs", createdAtMs).put("recordingStartedElapsedMs", JSONObject.NULL)
            .put("durationMs", 4200).put("error", JSONObject.NULL).put("ownerToken", if (status == MobileMeetingStatus.RECORDING) "process" else JSONObject.NULL)

    private fun store(vararg entries: JSONObject) = Metadata(JSONArray(entries.toList()).toString())
    private fun audio(dir: File, name: String, bytes: ByteArray) = File(dir.apply { mkdirs() }, name).apply { writeBytes(bytes) }

    private fun move(scoped: Metadata, personal: Metadata, transfer: (File, File) -> Unit = ::linkOrCopy) =
        moveScopedRecordings(scope, scoped, personal, scopedDir, personalDir,
            locked = { block -> assertFalse(inLock); inLock = true; try { block() } finally { inLock = false } }, transfer = transfer)

    // A recording is reachable when one store lists it and its audio file is where that store looks.
    private fun reachable(scoped: Metadata, personal: Metadata, id: String, bytes: ByteArray): Boolean {
        inLock = true
        try {
            val inScoped = scoped.entry(id)?.let { File(scopedDir, it.getString("audioFileName")).readBytesOrNull() }
            val inPersonal = personal.entries().filter { it.getLong("createdAtMs") == scoped.entry(id)?.getLong("createdAtMs") || it.getString("id") in setOf(id, movedRecordingId(scope, id)) }
                .any { e -> !e.isNull("audioFileName") && File(personalDir, e.getString("audioFileName")).readBytesOrNull()?.contentEquals(bytes) == true }
            return inScoped?.contentEquals(bytes) == true || inPersonal
        } finally { inLock = false }
    }
    private fun File.readBytesOrNull() = takeIf { it.isFile }?.readBytes()

    @Test fun finishedRecordingsMoveToThePersonalLibraryAndTheScopedStoreIsRemoved() {
        val recorded = UUID.randomUUID().toString()
        val interrupted = UUID.randomUUID().toString()
        val draft = UUID.randomUUID().toString()
        val mine = UUID.randomUUID().toString()
        audio(scopedDir, "$recorded.m4a", byteArrayOf(1, 2, 3))
        audio(scopedDir, "$interrupted.m4a.partial", byteArrayOf(4, 5))
        audio(personalDir, "$mine.m4a", byteArrayOf(9))
        val scoped = store(entry(recorded), entry(interrupted, MobileMeetingStatus.INTERRUPTED, "$interrupted.m4a.partial"),
            entry(draft, MobileMeetingStatus.DRAFT, audio = null))
        val personal = store(entry(mine, title = "Personal").put("sourceEventKey", "calendar-event"))
        val personalBefore = personal.value!!.let { JSONArray(it).getJSONObject(0).toString() }

        assertEquals(RecordingMoveOutcome(moved = 2, deferred = 0, complete = true), move(scoped, personal))
        assertNull(scoped.value)
        assertFalse(scopedDir.exists())
        assertArrayEquals(byteArrayOf(1, 2, 3), File(personalDir, "$recorded.m4a").readBytes())
        assertArrayEquals(byteArrayOf(4, 5), File(personalDir, "$interrupted.m4a.partial").readBytes())
        assertArrayEquals(byteArrayOf(9), File(personalDir, "$mine.m4a").readBytes())
        assertEquals(setOf("$recorded.m4a", "$interrupted.m4a.partial", "$mine.m4a"), personalDir.list()!!.toSet())

        inLock = true
        val ids = personal.entries().map { it.getString("id") }
        assertEquals(setOf(recorded, interrupted, mine), ids.toSet())
        assertEquals(mine, ids.last())
        assertEquals(personalBefore, personal.entry(mine).toString())
        val moved = personal.entry(recorded)!!
        val original = entry(recorded)
        assertTrue(moved.isNull("sourceEventKey"))
        assertTrue(moved.isNull("ownerToken"))
        for (key in listOf("title", "createdAtMs", "durationMs", "status", "audioFileName", "recordingStartedAtMs")) {
            assertEquals(key, original.get(key).toString(), moved.get(key).toString())
        }
        assertEquals("INTERRUPTED", personal.entry(interrupted)!!.getString("status"))
        assertEquals("$interrupted.m4a.partial", personal.entry(interrupted)!!.getString("audioFileName"))
    }

    @Test fun aDifferentPersonalRecordingWithTheSameIdIsNeverOverwritten() {
        val id = UUID.randomUUID().toString()
        audio(scopedDir, "$id.m4a", byteArrayOf(1, 1))
        audio(personalDir, "$id.m4a", byteArrayOf(7, 7))
        val scoped = store(entry(id))
        val personal = store(entry(id, title = "Someone else", createdAtMs = 5))

        assertEquals(RecordingMoveOutcome(1, 0, true), move(scoped, personal))
        val renamed = movedRecordingId(scope, id)
        assertArrayEquals(byteArrayOf(7, 7), File(personalDir, "$id.m4a").readBytes())
        assertArrayEquals(byteArrayOf(1, 1), File(personalDir, "$renamed.m4a").readBytes())
        inLock = true
        assertEquals("Someone else", personal.entry(id)!!.getString("title"))
        assertEquals("$renamed.m4a", personal.entry(renamed)!!.getString("audioFileName"))
        assertEquals("Synthetic account recording", personal.entry(renamed)!!.getString("title"))
    }

    @Test fun aRecordingInProgressIsDeferredUntilItStops() {
        val live = UUID.randomUUID().toString()
        val done = UUID.randomUUID().toString()
        audio(scopedDir, "$live.m4a.partial", byteArrayOf(3))
        audio(scopedDir, "$done.m4a", byteArrayOf(4))
        val scoped = store(entry(live, MobileMeetingStatus.RECORDING, "$live.m4a.partial"), entry(done))
        val personal = Metadata(null)

        assertEquals(RecordingMoveOutcome(moved = 1, deferred = 1, complete = false), move(scoped, personal))
        assertTrue(File(scopedDir, "$live.m4a.partial").isFile)
        inLock = true
        assertNotNull(scoped.entry(live))
        assertNull(personal.entry(live))
        // The recorder stops and saves the file in the scoped store, then the move resumes.
        File(scopedDir, "$live.m4a.partial").renameTo(File(scopedDir, "$live.m4a"))
        scoped.value = JSONArray().put(entry(live)).toString()
        inLock = false

        assertEquals(RecordingMoveOutcome(1, 0, true), move(scoped, personal))
        assertArrayEquals(byteArrayOf(3), File(personalDir, "$live.m4a").readBytes())
        assertFalse(scopedDir.exists())
    }

    @Test fun anInterruptionAtAnyStepLeavesACopyAndARerunFinishesWithoutDuplicates() {
        val id = UUID.randomUUID().toString()
        val bytes = byteArrayOf(5, 6, 7)
        audio(scopedDir, "$id.m4a", bytes)
        val scoped = store(entry(id))
        val personal = Metadata(null)

        // 1. The audio transfer fails (for example, no space).
        assertThrows(IOException::class.java) { move(scoped, personal) { _, _ -> throw IOException("disk full") } }
        assertTrue(reachable(scoped, personal, id, bytes))
        inLock = true; assertNull(personal.value); inLock = false

        // 2. The audio is in place but the personal metadata cannot be written.
        personal.failWrites = true
        assertThrows(IllegalStateException::class.java) { move(scoped, personal) }
        assertTrue(File(personalDir, "$id.m4a").isFile)
        assertTrue(reachable(scoped, personal, id, bytes))

        // 3. The personal store has it, but the scoped store cannot be updated: both copies exist.
        personal.failWrites = false
        scoped.failWrites = true
        assertThrows(IllegalStateException::class.java) { move(scoped, personal) }
        inLock = true
        assertNotNull(scoped.entry(id))
        assertNotNull(personal.entry(id))
        inLock = false
        assertTrue(File(scopedDir, "$id.m4a").isFile)

        // The rerun recognises the earlier copy instead of adding a second one.
        scoped.failWrites = false
        assertEquals(RecordingMoveOutcome(moved = 0, deferred = 0, complete = true), move(scoped, personal))
        inLock = true
        assertEquals(listOf(id), personal.entries().map { it.getString("id") })
        inLock = false
        assertArrayEquals(bytes, File(personalDir, "$id.m4a").readBytes())
        assertFalse(scopedDir.exists())
        assertEquals(listOf("$id.m4a"), personalDir.list()!!.toList())
    }

    @Test fun leftoverScopedFilesAfterTheLastMetadataUpdateAreRemoved() {
        audio(scopedDir, "${UUID.randomUUID()}.m4a", byteArrayOf(1))
        val scoped = Metadata("[]")
        assertEquals(RecordingMoveOutcome(0, 0, true), move(scoped, Metadata(null)))
        assertNull(scoped.value)
        assertFalse(scopedDir.exists())
    }

    @Test fun unreadableMetadataMovesNothing() {
        val id = UUID.randomUUID().toString()
        audio(scopedDir, "$id.m4a", byteArrayOf(1))
        val brokenScoped = Metadata("{not json")
        assertEquals(RecordingMoveOutcome(0, 0, false), move(brokenScoped, Metadata(null)))
        assertEquals("{not json", brokenScoped.value)

        val scoped = store(entry(id))
        val brokenPersonal = Metadata("{not json")
        assertEquals(RecordingMoveOutcome(0, 0, false), move(scoped, brokenPersonal))
        assertEquals("{not json", brokenPersonal.value)
        assertTrue(File(scopedDir, "$id.m4a").isFile)
        inLock = true; assertNotNull(scoped.entry(id)); inLock = false
        assertFalse(File(personalDir, "$id.m4a").exists())
    }

    @Test fun linkOrCopyKeepsTheSourceAndReplacesAStaleTarget() {
        val source = audio(tmp.root, "source.m4a", byteArrayOf(1, 2))
        val target = audio(tmp.root, "target.m4a", byteArrayOf(9, 9, 9))
        linkOrCopy(source, target)
        assertArrayEquals(byteArrayOf(1, 2), target.readBytes())
        assertArrayEquals(byteArrayOf(1, 2), source.readBytes())
        source.delete()
        assertArrayEquals(byteArrayOf(1, 2), target.readBytes())
    }
}
