package app.halle.companion

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.time.Instant
import java.util.UUID

class AccountLifecycleTest {
    @get:Rule val tmp = TemporaryFolder()
    private val session = AccountSession("https://account.invalid", "user-1", "secret-token-1", Long.MAX_VALUE)
    private val storage = MemoryCalendarStorage()
    private val cacheDir by lazy { File(tmp.root, "account-transcripts/${session.scope}") }
    private val cache by lazy { AccountTranscriptCache(cacheDir) }
    private val cal by lazy { calendar(session) }
    private val mid = UUID.randomUUID().toString()
    private val rid = UUID.randomUUID().toString()
    private val rid2 = UUID.randomUUID().toString()
    private val text = "Speaker 1: Synthetic señora — 会议 transcript.\n"
    private val textBytes = text.toByteArray(Charsets.UTF_8).size.toLong()

    private fun calendar(s: AccountSession, store: CalendarStorage = storage, transcripts: AccountTranscriptCache = cache) =
        AccountCalendar(s, store, null, recoverAudio = {}, completedAudioFile = { null }, transcripts = transcripts)

    private fun lazyRecording(id: String, available: Boolean, bytes: Long? = if (available) textBytes else null,
                              status: String = "completed") =
        JSONObject().put("id", id).put("status", status).put("transcript", JSONObject.NULL)
            .put("transcriptAvailable", available).put("transcriptBytes", bytes ?: JSONObject.NULL)

    private fun meeting(id: String, vararg recordings: JSONObject) = JSONObject().put("id", id).put("title", "Synthetic")
        .put("startAt", "2026-11-20T10:00:00Z").put("endAt", "2026-11-20T10:30:00Z").put("revision", 1)
        .put("deleted", false).put("recordings", JSONArray(recordings.toList()))

    private fun pull(vararg meetings: JSONObject) {
        val paths = mutableListOf<String>()
        cal.sync { path, method, _, _ ->
            assertEquals("GET", method)
            paths += path
            JSONObject().put("version", UUID.randomUUID().toString().replace("-", "")).put("meetings", JSONArray(meetings.toList()))
        }
        assertTrue(paths.all { it.startsWith("/meetings?transcripts=lazy") })
    }

    private fun cachedFile(id: String) = File(cacheDir, "$id.txt")
    private fun dump(store: CalendarStorage) = store.keys("").associateWith { store.getString(it) }
    private val noFetch: (String) -> String = { throw AssertionError("unexpected transcript request $it") }

    @Test fun featuresDefaultToFalseUnlessTheServerSaysTrue() {
        assertEquals(AccountFeatures.NONE, AccountFeatures.from(null))
        assertEquals(AccountFeatures.NONE, AccountFeatures.from(JSONObject().put("userId", "user-1")))
        assertEquals(AccountFeatures.NONE, AccountFeatures.from(JSONObject().put("features",
            JSONObject().put("accountDeletion", "true").put("lazyTranscripts", 1))))
        assertEquals(AccountFeatures(accountDeletion = false, lazyTranscripts = true), AccountFeatures.from(JSONObject()
            .put("features", JSONObject().put("lazyTranscripts", true))))
        assertEquals(AccountFeatures(accountDeletion = true, lazyTranscripts = true), AccountFeatures.from(JSONObject()
            .put("features", JSONObject().put("accountDeletion", true).put("lazyTranscripts", true))))
    }

    @Test fun featuresAreFetchedOncePerSignedInSession() {
        assertEquals(AccountFeatures.NONE, cal.features())
        val calls = mutableListOf<String>()
        var reply = JSONObject().put("userId", "user-1").put("expiresAt", 1)
            .put("features", JSONObject().put("accountDeletion", true).put("lazyTranscripts", true))
        val request: (String, String, JSONObject?, ByteArray?) -> JSONObject = { path, method, body, bytes ->
            calls += "$method $path"; assertNull(body); assertNull(bytes); reply
        }
        repeat(2) { assertTrue(cal.refreshFeatures(request).accountDeletion) }
        assertEquals(listOf("GET /auth/session"), calls)
        assertTrue(cal.features().accountDeletion)
        // The cache is bound to the session without storing its bearer token.
        assertFalse(storage.getString("features")!!.contains(session.token))

        // A new sign-in to the same account asks again; a reply without features means both are off.
        val next = calendar(session.copy(token = "secret-token-2"))
        assertEquals(AccountFeatures.NONE, next.features())
        reply = JSONObject().put("userId", "user-1").put("expiresAt", 1)
        assertEquals(AccountFeatures.NONE, next.refreshFeatures(request))
        assertEquals(2, calls.size)
        next.refreshFeatures(request)
        assertEquals(2, calls.size)

        // A reply for another account is never cached.
        val third = calendar(session.copy(token = "secret-token-3"))
        reply = JSONObject().put("userId", "someone-else").put("features", JSONObject().put("accountDeletion", true))
        assertThrows(IllegalStateException::class.java) { third.refreshFeatures(request) }
        assertEquals(AccountFeatures.NONE, third.features())
    }

    @Test fun deletionRequiresTheTypedWordExactly() {
        assertTrue(isAccountDeletionConfirmed("DELETE"))
        assertTrue(isAccountDeletionConfirmed("  DELETE\n"))
        for (typed in listOf("", "delete", "Delete", "DELETE!", "DEL ETE", "DELETED")) assertFalse(typed, isAccountDeletionConfirmed(typed))
    }

    @Test fun acceptedDeletionWipesOnlyThisAccountAndKeepsPhoneRecordings() {
        pull(meeting(mid, lazyRecording(rid, available = true)))
        assertEquals(text, cal.loadTranscript(mid, rid) { text })
        cal.stage(UUID.randomUUID().toString(), "Queued", Instant.parse("2026-11-21T10:00:00Z"),
            Instant.parse("2026-11-21T11:00:00Z"), 0, false)
        cal.enqueueAudio(mid, rid2, "deepgram")
        cal.refreshFeatures { _, _, _, _ -> JSONObject().put("features", JSONObject().put("accountDeletion", true)) }
        assertTrue(storage.keys("").containsAll(listOf("snapshot", "version", "features")))
        assertTrue(cachedFile(rid).isFile)
        val phoneRecording = File(tmp.root, "account-audio/${session.scope}/$rid2.m4a").apply {
            parentFile.mkdirs(); writeBytes(byteArrayOf(1, 2, 3))
        }
        val other = AccountSession("https://account.invalid", "user-2", "other-token", Long.MAX_VALUE)
        val otherStorage = MemoryCalendarStorage().apply { commit(mapOf("snapshot" to "[]", "version" to "f".repeat(32))) }
        val otherCacheDir = File(tmp.root, "account-transcripts/${other.scope}")
        AccountTranscriptCache(otherCacheDir).write(rid, "other account") { true }

        val calls = mutableListOf<String>()
        var forgotten = 0
        cal.deleteAccount({ path, method, body, bytes ->
            calls += "$method $path"
            assertEquals(JSONObject().put("confirmation", "DELETE").toString(), body.toString())
            assertNull(bytes)
            JSONObject().put("status", "deleting")
        }) { forgotten++ }

        assertEquals(listOf("POST /account/delete"), calls)
        assertEquals(1, forgotten)
        assertEquals(emptyList<String>(), storage.keys(""))
        assertTrue(cal.cached().isEmpty())
        assertTrue(cal.mutationIds().isEmpty())
        assertNull(cal.upload(rid2))
        assertEquals(AccountFeatures.NONE, cal.features())
        assertFalse(cacheDir.exists())
        assertArrayEquals(byteArrayOf(1, 2, 3), phoneRecording.readBytes())
        assertEquals(listOf("snapshot", "version"), otherStorage.keys(""))
        assertEquals("other account", File(otherCacheDir, "$rid.txt").readText())
    }

    @Test fun refusedOrFailedDeletionChangesNothing() {
        pull(meeting(mid, lazyRecording(rid, available = true)))
        cal.loadTranscript(mid, rid) { text }
        cal.stage(mid, "Edited", Instant.parse("2026-11-20T10:00:00Z"), Instant.parse("2026-11-20T10:30:00Z"), 1, false)
        val before = dump(storage)
        val failures: List<() -> JSONObject> = listOf(
            { throw AccountHttpError(403, "deletion_disabled") },
            { throw AccountHttpError(400, "confirmation_required") },
            { throw AccountHttpError(401, "unauthorized") },
            { throw AccountHttpError(503, null) },
            { throw IOException("offline") },
            { JSONObject() },
            { JSONObject().put("status", "deleted") },
        )
        for (failure in failures) {
            var forgotten = 0
            val error = runCatching { cal.deleteAccount({ _, _, _, _ -> failure() }) { forgotten++ } }.exceptionOrNull()
            assertNotNull(error)
            assertFalse(error is LocalWipeIncomplete)
            assertEquals(0, forgotten)
            assertEquals(before, dump(storage))
            assertEquals(text, cachedFile(rid).readText())
        }
        val disabled = assertThrows(AccountHttpError::class.java) {
            cal.deleteAccount({ _, _, _, _ -> throw AccountHttpError(403, "deletion_disabled") }) {}
        }
        assertEquals("deletion_disabled", disabled.reason)
    }

    @Test fun theSessionIsForgottenEvenWhenTheLocalWipeFails() {
        val broken = object : CalendarStorage by storage {
            override fun commit(edits: Map<String, String?>) = false
        }
        var forgotten = 0
        assertThrows(LocalWipeIncomplete::class.java) {
            calendar(session, broken).deleteAccount({ _, _, _, _ -> JSONObject().put("status", "deleting") }) { forgotten++ }
        }
        assertEquals(1, forgotten)
    }

    @Test fun lazyTranscriptIsFetchedOnceCachedAndEvictedWithItsRecording() {
        pull(meeting(mid, lazyRecording(rid, available = true), lazyRecording(rid2, available = false)))
        val listed = cal.cached().single().getJSONArray("recordings").objects()
        assertTrue(hasRemoteTranscript(listed[0]))
        assertFalse(hasRemoteTranscript(listed[1]))
        assertNull(cal.cachedTranscript(listed[0]))

        val paths = mutableListOf<String>()
        assertEquals(text, cal.loadTranscript(mid, rid.uppercase()) { path -> paths += path; text })
        assertEquals(listOf("/meetings/$mid/recordings/$rid/transcript"), paths)
        assertEquals(text, cal.loadTranscript(mid, rid, noFetch))
        assertEquals(text, cal.cachedTranscript(listed[0]))

        // 404: there is no transcript, and nothing is cached.
        assertNull(cal.loadTranscript(mid, rid2) { throw AccountHttpError(404, "not_found") })
        assertFalse(cachedFile(rid2).exists())
        assertThrows(AccountHttpError::class.java) { cal.loadTranscript(mid, rid2) { throw AccountHttpError(503, null) } }

        // The next pull no longer lists the recording: its copy is removed.
        pull(meeting(mid, lazyRecording(rid2, available = false)))
        assertFalse(cachedFile(rid).exists())
        assertNull(cal.cachedTranscript(listed[0]))

        // A recording that now reports no transcript also loses its copy.
        pull(meeting(mid, lazyRecording(rid, available = true)))
        cal.loadTranscript(mid, rid) { text }
        pull(meeting(mid, lazyRecording(rid, available = false)))
        assertFalse(cachedFile(rid).exists())
    }

    @Test fun aCopyThatDoesNotMatchTheAnnouncedSizeIsFetchedAgain() {
        pull(meeting(mid, lazyRecording(rid, available = true, bytes = textBytes + 1)))
        var fetches = 0
        repeat(2) { assertEquals(text, cal.loadTranscript(mid, rid) { fetches++; text }) }
        assertEquals(2, fetches)
        // Without an announced size the cached copy is used.
        pull(meeting(mid, lazyRecording(rid, available = true, bytes = null)))
        assertEquals(text, cal.loadTranscript(mid, rid, noFetch))
    }

    @Test fun aTranscriptArrivingAfterItsRecordingLeftTheSnapshotOrAfterAWipeIsNotCached() {
        pull(meeting(mid, lazyRecording(rid, available = true)))
        assertEquals(text, cal.loadTranscript(mid, rid) {
            storage.commit(mapOf("snapshot" to JSONArray().put(meeting(mid)).toString()))
            text
        })
        assertFalse(cachedFile(rid).exists())

        pull(meeting(mid, lazyRecording(rid, available = true)))
        assertEquals(text, cal.loadTranscript(mid, rid) { cal.forgetAccount(); text })
        assertFalse(cachedFile(rid).exists())
    }

    @Test fun discardingARemoteRecordingEvictsItsTranscript() {
        pull(meeting(mid, lazyRecording(rid, available = true, status = "review"), lazyRecording(rid2, available = true)))
        cal.loadTranscript(mid, rid) { text }
        cal.loadTranscript(mid, rid2) { text }
        assertTrue(cal.discardRemoteRecording(mid, rid) { _, _, _, _ -> JSONObject() })
        assertFalse(cachedFile(rid).exists())
        assertTrue(cachedFile(rid2).isFile)
    }

    @Test fun inlineTranscriptsFromOldSnapshotsAreStillRead() {
        val inline = JSONObject().put("id", rid).put("status", "completed").put("transcript", "Inline synthetic text")
        assertEquals("Inline synthetic text", inlineTranscript(inline))
        assertFalse(hasRemoteTranscript(inline))
        val separate = JSONObject().put("id", rid).put("transcript", JSONObject.NULL).put("transcriptStoredSeparately", true)
        assertNull(inlineTranscript(separate))
        assertTrue(hasRemoteTranscript(separate))
        assertFalse(hasRemoteTranscript(JSONObject().put("id", rid).put("transcript", JSONObject.NULL)))
        assertFalse(hasRemoteTranscript(JSONObject().put("id", rid)))

        // A snapshot pulled before lazy transcripts stays in use when the lazy pull reports no change.
        val version = "0123456789abcdef0123456789abcdef"
        storage.commit(mapOf("snapshot" to JSONArray().put(meeting(mid, inline)).toString(), "version" to version))
        val paths = mutableListOf<String>()
        cal.sync { path, _, _, _ -> paths += path; JSONObject().put("unchanged", true).put("version", version) }
        assertEquals(listOf("/meetings?transcripts=lazy&since=$version"), paths)
        assertEquals("Inline synthetic text",
            inlineTranscript(cal.cached().single().getJSONArray("recordings").getJSONObject(0)))
    }

    @Test fun transcriptRepliesMustBeBoundedPlainText() {
        fun body(bytes: ByteArray) = ByteArrayInputStream(bytes)
        assertEquals(text, transcriptText("text/plain; charset=utf-8", body(text.toByteArray())))
        assertEquals(text, transcriptText("Text/Plain", body(text.toByteArray())))
        for (type in listOf(null, "application/json", "text/html; charset=utf-8")) {
            assertThrows(IOException::class.java) { transcriptText(type, body(text.toByteArray())) }
        }
        assertEquals(MAX_TRANSCRIPT_BYTES, transcriptText("text/plain", body(ByteArray(MAX_TRANSCRIPT_BYTES) { 'a'.code.toByte() })).length)
        assertThrows(IOException::class.java) { transcriptText("text/plain", body(ByteArray(MAX_TRANSCRIPT_BYTES + 1))) }
    }

    @Test fun transcriptCacheAcceptsOnlyRecordingIdsAndRemovesLeftovers() {
        assertThrows(IllegalArgumentException::class.java) { cache.write("../escape", text) { true } }
        assertThrows(IllegalArgumentException::class.java) { cache.read("not-a-uuid") }
        assertFalse(cache.write(rid, text) { false })
        assertFalse(cacheDir.exists())
        assertTrue(cache.write(rid.uppercase(), text) { true })
        assertEquals(text, cache.read(rid))
        assertEquals(text, cache.read(rid, textBytes))
        assertNull(cache.read(rid, textBytes + 1))
        File(cacheDir, "$rid2.partial").writeText("interrupted")
        File(cacheDir, "stray").writeText("x")
        cache.retain(setOf(rid.uppercase()))
        assertEquals(listOf("$rid.txt"), cacheDir.list()!!.toList())
        assertTrue(cache.clear())
        assertFalse(cacheDir.exists())
        assertTrue(cache.clear())
    }
}
