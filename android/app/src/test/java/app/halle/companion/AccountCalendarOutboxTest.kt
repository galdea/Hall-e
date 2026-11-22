package app.halle.companion

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.time.Instant
import java.util.UUID

class AccountCalendarOutboxTest {
    private val session = AccountSession("https://account.invalid", "user-1", "tok", Long.MAX_VALUE)
    private val storage = MemoryCalendarStorage()
    private val cal = AccountCalendar(session, storage, null, recoverAudio = {}, completedAudioFile = { null })
    private val start = Instant.parse("2026-11-20T10:00:00Z")
    private val end = Instant.parse("2026-11-20T10:30:00Z")
    private val project = AccountProject(UUID.randomUUID(), "Synthetic project")

    private fun row(id: String, title: String = "Meeting", revision: Int = 1, deleted: Boolean = false,
                    at: Instant = start, recordings: JSONArray = JSONArray()) =
        JSONObject().put("id", id).put("title", if (deleted) "" else title).put("startAt", at.toString())
            .put("endAt", at.plusSeconds(1800).toString()).put("revision", revision).put("deleted", deleted)
            .put("recordings", recordings)

    private fun seed(vararg rows: JSONObject) {
        storage.commit(mapOf("snapshot" to JSONArray(rows.toList()).toString(),
            "version" to "0123456789abcdef0123456789abcdef"))
    }

    private fun snapshotReply(vararg rows: JSONObject) =
        JSONObject().put("version", "fedcba9876543210fedcba9876543210").put("meetings", JSONArray(rows.toList()))

    @Test fun stagedEditIsClearedAndSnapshotUpdatedInOneCommitAfterAcceptedPut() {
        val id = UUID.randomUUID().toString()
        val recordings = JSONArray().put(JSONObject().put("id", UUID.randomUUID().toString()))
        seed(row(id, "Before", revision = 1, recordings = recordings))
        cal.stage(id, "  After  ", start, end, base = 1, deleting = false)
        val staged = cal.pending(id)!!
        assertEquals("After", staged.getString("title"))
        assertThrows(IllegalStateException::class.java) { cal.stage(id, "Again", start, end, base = 1, deleting = false) }

        val sent = mutableListOf<JSONObject>()
        // The follow-up pull fails; the accepted PUT must already be persisted with the edit cleared.
        assertThrows(IOException::class.java) {
            cal.sync { path, method, body, _ ->
                if (method == "PUT") {
                    assertEquals("/meetings/$id", path)
                    sent += body!!
                    JSONObject().put("meeting", row(id, "After", revision = 2).apply { remove("recordings") })
                } else throw IOException("offline after PUT")
            }
        }
        assertEquals(1, sent.size)
        assertEquals(staged.getString("mutationId"), sent.single().getString("mutationId"))
        assertEquals(1, sent.single().getInt("baseRevision"))
        assertFalse(sent.single().has("projectAtEdit"))
        assertNull(cal.pending(id))
        assertNull(storage.getString("version"))
        val cached = cal.cached().single()
        assertEquals("After", cached.getString("title"))
        assertEquals(2, cached.getInt("revision"))
        assertEquals(recordings.toString(), cached.getJSONArray("recordings").toString())

        val calls = mutableListOf<String>()
        cal.sync { path, method, _, _ ->
            calls += "$method $path"
            snapshotReply(row(id, "After", revision = 2, recordings = recordings))
        }
        assertEquals(listOf("GET /meetings"), calls)
        assertEquals("fedcba9876543210fedcba9876543210", storage.getString("version"))
        assertEquals(listOf("After"), cal.visible().map { it.getString("title") })
    }

    @Test fun permanentConflictAndMissingMeetingMarkProblemWhileTransientErrorsRetry() {
        val conflicted = UUID.randomUUID().toString()
        val missing = UUID.randomUUID().toString()
        val transient = UUID.randomUUID().toString()
        seed(row(conflicted), row(missing), row(transient))
        for (id in listOf(conflicted, missing)) cal.stage(id, "Phone edit", start, end, base = 1, deleting = false)
        cal.sync { path, method, _, _ ->
            when {
                method == "GET" -> snapshotReply(row(conflicted, revision = 2), row(missing), row(transient))
                path.endsWith(conflicted) -> throw AccountHttpError(409, "revision_conflict")
                else -> throw AccountHttpError(404, "not_found")
            }
        }
        assertEquals(409, cal.pending(conflicted)!!.getInt("problem"))
        assertEquals(404, cal.pending(missing)!!.getInt("problem"))

        // A problem entry is not sent again until the user resolves it.
        cal.stage(transient, "Phone edit", start, end, base = 1, deleting = false)
        val puts = mutableListOf<String>()
        for (status in listOf(401, 429, 503)) {
            assertThrows(AccountHttpError::class.java) {
                cal.sync { path, method, _, _ ->
                    if (method == "PUT") { puts += path; throw AccountHttpError(status, null) }
                    snapshotReply()
                }
            }
            assertFalse(cal.pending(transient)!!.has("problem"))
        }
        assertEquals(List(3) { "/meetings/$transient" }, puts)
    }

    @Test fun ignoredProjectAssignmentBecomesUnsupportedProjectAndCanBeRetried() {
        val id = UUID.randomUUID().toString()
        seed(row(id, "Before", revision = 4))
        cal.stage(id, "After", start, end, base = 4, deleting = false, project = ProjectChange(project))
        val original = cal.pending(id)!!.getString("mutationId")
        assertThrows(IllegalStateException::class.java) { cal.retryProject(id) }

        var bodies = 0
        // An older server acknowledges the meeting but drops the project assignment.
        cal.sync { _, method, body, _ ->
            if (method == "PUT") {
                bodies++
                assertEquals(project, AccountProject.read(body!!.getJSONObject("project")))
                JSONObject().put("meeting", row(id, "Server title", revision = 5))
            } else snapshotReply(row(id, "Server title", revision = 5))
        }
        assertEquals(1, bodies)
        val unsupported = cal.pending(id)!!
        assertEquals("unsupported_project", unsupported.getString("problem"))
        assertEquals(5, unsupported.getInt("baseRevision"))
        assertEquals("Server title", unsupported.getString("title"))
        assertNotEquals(original, unsupported.getString("mutationId"))
        assertEquals(project, AccountProject.read(unsupported.getJSONObject("project")))
        assertEquals(5, cal.cached().single().getInt("revision"))

        cal.retryProject(id)
        val retried = cal.pending(id)!!
        assertFalse(retried.has("problem"))
        assertEquals(unsupported.getString("mutationId"), retried.getString("mutationId"))
        cal.sync { _, method, _, _ ->
            if (method == "PUT") JSONObject().put("meeting", row(id, "Server title", revision = 6).put("project", project.json()))
            else snapshotReply(row(id, "Server title", revision = 6).put("project", project.json()))
        }
        assertNull(cal.pending(id))
        assertEquals(listOf(project), cal.projects())
    }

    @Test fun ignoredProjectOnAReplayedNewerRevisionIsAConflict() {
        val id = UUID.randomUUID().toString()
        seed(row(id, revision = 1))
        cal.stage(id, "After", start, end, base = 1, deleting = false, project = ProjectChange(project))
        cal.sync { _, method, _, _ ->
            if (method == "PUT") JSONObject().put("meeting", row(id, "Changed elsewhere", revision = 3))
            else snapshotReply(row(id, "Changed elsewhere", revision = 3))
        }
        assertEquals(409, cal.pending(id)!!.getInt("problem"))
        assertThrows(IllegalStateException::class.java) { cal.retryProject(id) }
    }

    @Test fun visibleKeepsPendingDeletesAndConflictsButHidesConfirmedDeletes() {
        val live = UUID.randomUUID().toString()
        val confirmedDelete = UUID.randomUUID().toString()
        val pendingDelete = UUID.randomUUID().toString()
        val conflictedOnDeleted = UUID.randomUUID().toString()
        val edited = UUID.randomUUID().toString()
        val recordings = JSONArray().put(JSONObject().put("id", UUID.randomUUID().toString()))
        seed(row(live, "Live", at = start.plusSeconds(3600)),
            row(confirmedDelete, revision = 3, deleted = true),
            row(pendingDelete, "Going", at = start.plusSeconds(7200)),
            row(conflictedOnDeleted, revision = 2, deleted = true, at = start.plusSeconds(60)),
            row(edited, "Old title", revision = 7, at = start.plusSeconds(10800), recordings = recordings))
        cal.stage(pendingDelete, "Going", start.plusSeconds(7200), start.plusSeconds(9000), base = 1, deleting = true)
        cal.stage(conflictedOnDeleted, "Phone edit", start, end, base = 1, deleting = false)
        storage.commit(mapOf("edit-$conflictedOnDeleted" to cal.pending(conflictedOnDeleted)!!.put("problem", 409).toString()))
        cal.stage(edited, "New title", start.plusSeconds(10800), start.plusSeconds(12600), base = 7, deleting = false)

        val shown = cal.visible().associateBy { it.getString("id") }
        assertEquals(setOf(live, pendingDelete, conflictedOnDeleted, edited), shown.keys)
        assertTrue(shown.getValue(pendingDelete).getBoolean("deleted"))
        // A conflict shows the server row, not the rejected local overlay.
        assertTrue(shown.getValue(conflictedOnDeleted).getBoolean("deleted"))
        assertEquals("", shown.getValue(conflictedOnDeleted).getString("title"))
        assertEquals("New title", shown.getValue(edited).getString("title"))
        assertEquals(7, shown.getValue(edited).getInt("revision"))
        assertEquals(recordings.toString(), shown.getValue(edited).getJSONArray("recordings").toString())
        assertEquals(listOf(conflictedOnDeleted, live, pendingDelete, edited), cal.visible().map { it.getString("id") })
    }

    @Test fun discardDropsThePendingChangeAndRestoresTheServerRow() {
        val id = UUID.randomUUID().toString()
        seed(row(id, "Server", revision = 2))
        cal.stage(id, "Local", start, end, base = 2, deleting = true)
        assertTrue(cal.visible().single().getBoolean("deleted"))
        cal.discard(id)
        assertNull(cal.pending(id))
        assertTrue(cal.mutationIds().isEmpty())
        assertEquals("Server", cal.visible().single().getString("title"))
        var puts = 0
        cal.sync { _, method, _, _ -> if (method == "PUT") puts++; snapshotReply(row(id, "Server", revision = 2)) }
        assertEquals(0, puts)
        cal.stage(id, "Local again", start, end, base = 2, deleting = false)
        assertNotNull(cal.pending(id))
    }

    @Test fun discardRecordingSendsDeleteAndHidesItOnlyAfterTheServerAgrees() {
        val id = UUID.randomUUID().toString()
        val failed = UUID.randomUUID().toString()
        val queued = UUID.randomUUID().toString()
        val recordings = JSONArray().put(JSONObject().put("id", failed).put("status", "failed"))
            .put(JSONObject().put("id", queued).put("status", "queued"))
        seed(row(id, recordings = recordings))
        assertTrue(isDiscardableRecording(JSONObject().put("status", "review")))
        assertTrue(isDiscardableRecording(JSONObject().put("status", "failed")))
        assertFalse(isDiscardableRecording(JSONObject().put("status", "queued")))
        assertFalse(isDiscardableRecording(JSONObject()))

        val calls = mutableListOf<String>()
        // 409 recording_active: nothing changes locally.
        assertFalse(cal.discardRemoteRecording(id, queued) { path, method, body, bytes ->
            calls += "$method $path"; assertNull(body); assertNull(bytes)
            throw AccountHttpError(409, "recording_active")
        })
        assertEquals(2, cal.cached().single().getJSONArray("recordings").length())
        assertEquals("0123456789abcdef0123456789abcdef", storage.getString("version"))

        // Other failures propagate and also leave the snapshot alone.
        assertThrows(AccountHttpError::class.java) {
            cal.discardRemoteRecording(id, failed) { _, _, _, _ -> throw AccountHttpError(503, null) }
        }
        assertEquals(2, cal.cached().single().getJSONArray("recordings").length())

        // 204 (an empty reply) removes just that recording and forces a full pull next time; a retry is also 204.
        repeat(2) {
            assertTrue(cal.discardRemoteRecording(id, failed.uppercase()) { path, method, _, _ ->
                calls += "$method $path"; JSONObject()
            })
        }
        val left = cal.cached().single().getJSONArray("recordings")
        assertEquals(1, left.length())
        assertEquals(queued, left.getJSONObject(0).getString("id"))
        assertNull(storage.getString("version"))
        assertEquals(listOf("DELETE /meetings/$id/recordings/$queued") +
            List(2) { "DELETE /meetings/$id/recordings/$failed" }, calls)
        assertThrows(IllegalArgumentException::class.java) {
            cal.discardRemoteRecording(id, "not-a-uuid") { _, _, _, _ -> JSONObject() }
        }
    }
}
