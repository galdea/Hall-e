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
}
