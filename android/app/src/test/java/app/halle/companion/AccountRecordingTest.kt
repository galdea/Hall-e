package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.util.UUID

class AccountRecordingTest {
    @get:Rule val tmp = TemporaryFolder()
    private val rid = UUID.randomUUID().toString()
    private val mid = UUID.randomUUID().toString()

    @Test fun originAndAccountDetermineOutboxEvenWhenTokensRotate() {
        val a = AccountSession(accountOrigin("https://SERVICE.invalid:443/account/v1"), "alice", "first", 1)
        assertEquals(a.scope, a.copy(token = "new", expiresAt = 9).scope)
        assertNotEquals(a.scope, a.copy(origin = "https://other.invalid").scope)
        assertNotEquals(a.scope, a.copy(userId = "bob").scope)
        assertThrows(IllegalArgumentException::class.java) { accountOrigin("http://server.invalid") }
        assertThrows(IllegalArgumentException::class.java) { accountOrigin("https://me@server.invalid") }
        assertThrows(IllegalArgumentException::class.java) { accountOrigin("https://server.invalid/redirect?to=example.invalid") }
    }

    @Test fun validSnapshotVersionSelectsConditionalPull() {
        val version = "0123456789abcdef0123456789abcdef"
        assertEquals("/meetings?since=$version", snapshotPath(version))
        assertEquals("/meetings", snapshotPath(null))
        assertEquals("/meetings", snapshotPath("stale or unsupported"))
    }

    @Test fun recoveredOutboxReplaysLostAckWithoutDuplicatingAudioOrJob() {
        val file = tmp.newFile().apply { writeBytes(ByteArray(13) { it.toByte() }) }
        val outbox = tmp.newFile()
        val initial = JSONObject().put("meeting", mid).put("provider", "speechmatics").put("nextPart", 0)
        outbox.writeText(initial.toString())
        val saved = mutableMapOf<Int, ByteArray>()
        var jobCount = 0
        var losePartResponse = true
        var loseCompleteResponse = true
        val request: (String, String, JSONObject?, ByteArray?) -> JSONObject = { path, method, body, bytes ->
            assertTrue(path.startsWith("/meetings/$mid/recordings/$rid"))
            when {
                path.endsWith("/complete") -> {
                    assertEquals("POST", method)
                    assertArrayEquals(file.readBytes(), saved.toSortedMap().values.fold(byteArrayOf()) { acc, raw -> acc + raw })
                    jobCount++
                    if (loseCompleteResponse) { loseCompleteResponse = false; throw IOException("simulated lost completion response") }
                    JSONObject()
                }
                bytes != null -> {
                    val index = path.substringAfterLast("/").toInt()
                    assertEquals("PUT", method)
                    saved.putIfAbsent(index, bytes)?.let { assertArrayEquals(it, bytes) }
                    if (index == 1 && losePartResponse) { losePartResponse = false; throw IOException("simulated disconnect") }
                    JSONObject()
                }
                else -> {
                    assertEquals("eu1", body!!.getString("region"))
                    assertEquals("speechmatics", body.getString("provider"))
                    assertTrue(body.getBoolean("consent"))
                    assertEquals(13, body.getInt("size"))
                    JSONObject().put("status", if (jobCount == 0) "uploading" else "queued").put("partSize", 4)
                }
            }
        }
        fun restart() {
            val state = JSONObject(outbox.readText())
            sendAccountRecording(rid, state, file, request) { outbox.writeText(state.toString()) }
        }
        assertThrows(IOException::class.java) { restart() }
        assertEquals(1, JSONObject(outbox.readText()).getInt("nextPart"))
        assertThrows(IOException::class.java) { restart() }
        restart()
        assertEquals(1, jobCount)
        assertEquals(4, saved.size)
    }

    @Test fun interruptedMicrophoneKeepsPartialBytesAndRecognizesAlreadyFinalizedFiles() {
        val directory = tmp.newFolder()
        val partial = "$rid.m4a.partial"
        val active = MobileMeeting(rid, "Synthetic", null, 10, null, null, mid, null,
            MobileMeetingStatus.RECORDING, partial, 10, 20, 0, null)
        val file = java.io.File(directory, partial).apply { writeBytes(byteArrayOf(1,2,3)) }
        assertNull(recoverRecording(active, "same", "same", directory))
        val interrupted = recoverRecording(active, "old", "new", directory)!!
        assertEquals(MobileMeetingStatus.INTERRUPTED, interrupted.status)
        assertEquals(partial, interrupted.audioFileName)
        assertTrue(file.isFile)
        val final = java.io.File(directory, "$rid.m4a")
        assertTrue(file.renameTo(final))
        val recovered = recoverRecording(active, "old", "new", directory)!!
        assertEquals(final.name, recovered.audioFileName)
        assertNull(recoverRecording(recovered, null, "next", directory))
    }

    @Test fun expiredUploadReplaysAcknowledgedPartsAfterThePhoneReturns() {
        val file = tmp.newFile().apply { writeBytes(ByteArray(6) { it.toByte() }) }
        val state = JSONObject().put("meeting", mid).put("provider", "deepgram").put("nextPart", 1)
        val parts = mutableSetOf<Int>()
        sendAccountRecording(rid, state, file, { path, _, _, bytes ->
            if (bytes != null) parts += path.substringAfterLast("/").toInt()
            if (path.endsWith("/complete") && parts.size != 2) throw AccountHttpError(409, "missing_parts")
            JSONObject().put("status", "uploading").put("partSize", 3)
        }) {}
        assertEquals(setOf(0,1), parts)
    }

    private class MemoryCalendarStorage : CalendarStorage {
        private val data = mutableMapOf<String, String>()
        override fun getString(key: String, default: String?): String? = data[key] ?: default
        override fun keys(prefix: String): List<String> = data.keys.filter { it.startsWith(prefix) }.sorted()
        override fun commit(edits: Map<String, String?>): Boolean {
            for ((k, v) in edits) {
                if (v == null) data.remove(k) else data[k] = v
            }
            return true
        }
    }

    @Test fun syncReconcilesRemoteDeleteBeforeUploadAndSupportsRetryAndDiscard() {
        val session = AccountSession("https://account.invalid", "user-1", "tok", Long.MAX_VALUE)
        val storage = MemoryCalendarStorage()
        val audioFile = tmp.newFile("sample.m4a").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        val cal = AccountCalendar(session, storage, null, recoverAudio = {}, completedAudioFile = { if (it == rid) audioFile else null })
        cal.enqueueAudio(mid, rid, "deepgram")
        val calls = mutableListOf<String>()
        cal.sync { path, method, _, _ ->
            calls += "$method $path"
            assertEquals("GET", method)
            val deleted = JSONObject().put("id", mid).put("title", "").put("startAt", "2026-11-20T10:00:00Z")
                .put("endAt", "2026-11-20T10:30:00Z").put("revision", 2).put("deleted", true)
                .put("recordings", org.json.JSONArray())
            JSONObject().put("version", "0123456789abcdef0123456789abcdef").put("meetings", org.json.JSONArray().put(deleted))
        }
        assertEquals(listOf("GET /meetings"), calls)
        assertNull(cal.upload(rid))
        assertTrue(audioFile.isFile)

        // Permanent 409 marks problem; retryUpload clears problem; discardUpload removes outbox entry.
        val liveId = UUID.randomUUID().toString()
        cal.enqueueAudio(liveId, rid, "deepgram")
        cal.sync { path, method, _, _ ->
            if (method == "GET") {
                val live = JSONObject().put("id", liveId).put("title", "Live").put("startAt", "2026-11-20T10:00:00Z")
                    .put("endAt", "2026-11-20T10:30:00Z").put("revision", 1).put("deleted", false)
                    .put("recordings", org.json.JSONArray())
                JSONObject().put("version", "fedcba9876543210fedcba9876543210").put("meetings", org.json.JSONArray().put(live))
            } else throw AccountHttpError(409, "manifest_conflict")
        }
        assertEquals(409, cal.upload(rid)!!.getInt("problem"))
        cal.retryUpload(rid)
        assertFalse(cal.upload(rid)!!.has("problem"))
        cal.discardUpload(rid)
        assertNull(cal.upload(rid))
    }

    @Test fun reapplyRebasesConflictedEditOntoLatestServerRevisionAndRejectsDeletedTarget() {
        val session = AccountSession("https://account.invalid", "user-1", "tok", Long.MAX_VALUE)
        val storage = MemoryCalendarStorage()
        val cal = AccountCalendar(session, storage, null, recoverAudio = {}, completedAudioFile = { null })
        val start = java.time.Instant.parse("2026-11-20T12:00:00Z")
        val end = java.time.Instant.parse("2026-11-20T12:30:00Z")
        cal.stage(mid, "Phone title", start, end, base = 1, deleting = false)
        val originalMutation = cal.pending(mid)!!.getString("mutationId")
        var serverRev = 2
        var serverDeleted = false
        cal.sync { _, method, _, _ ->
            if (method == "PUT") throw AccountHttpError(409, "revision_conflict")
            val row = JSONObject().put("id", mid).put("title", "Mac title").put("startAt", start.toString())
                .put("endAt", end.toString()).put("revision", serverRev).put("deleted", serverDeleted)
                .put("recordings", org.json.JSONArray())
            JSONObject().put("version", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").put("meetings", org.json.JSONArray().put(row))
        }
        assertEquals(409, cal.pending(mid)!!.getInt("problem"))
        cal.reapply(mid)
        val rebased = cal.pending(mid)!!
        assertFalse(rebased.has("problem"))
        assertEquals(2, rebased.getInt("baseRevision"))
        assertNotEquals(originalMutation, rebased.getString("mutationId"))

        // If server later deletes the meeting and another conflict occurs, reapply refuses to resurrect it.
        serverRev = 3
        serverDeleted = true
        cal.sync { _, method, _, _ ->
            if (method == "PUT") throw AccountHttpError(409, "revision_conflict")
            val row = JSONObject().put("id", mid).put("title", "").put("startAt", start.toString())
                .put("endAt", end.toString()).put("revision", serverRev).put("deleted", true)
                .put("recordings", org.json.JSONArray())
            JSONObject().put("version", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").put("meetings", org.json.JSONArray().put(row))
        }
        assertThrows(IllegalStateException::class.java) { cal.reapply(mid) }
    }

    @Test fun googleAuthUrlValidationRequiresExactHostNoPortNoUserInfoAndExactPath() {
        assertTrue(isApprovedGoogleAuthUrl("https://accounts.google.com/o/oauth2/v2/auth?client_id=abc&state=xyz"))
        assertFalse(isApprovedGoogleAuthUrl("http://accounts.google.com/o/oauth2/v2/auth"))
        assertFalse(isApprovedGoogleAuthUrl("https://accounts.google.com:443/o/oauth2/v2/auth"))
        assertFalse(isApprovedGoogleAuthUrl("https://user@accounts.google.com/o/oauth2/v2/auth"))
        assertFalse(isApprovedGoogleAuthUrl("https://accounts.google.com/other"))
        assertFalse(isApprovedGoogleAuthUrl("https://evil.example/o/oauth2/v2/auth"))
    }
}
