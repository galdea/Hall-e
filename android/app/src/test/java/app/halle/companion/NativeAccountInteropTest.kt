package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.net.URI
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.util.UUID
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory

/** Runs against a pinned loopback fixture or the dedicated staging hostname with platform TLS. */
class NativeAccountInteropTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test fun editMacMeetingAndResumeAndroidUpload() {
        val fixturePath = System.getenv("HALL_E_NATIVE_QA")
        assumeTrue("Run via the native interop runner", !fixturePath.isNullOrBlank())
        val fixtureFile = File(requireNotNull(fixturePath))
        val fixture = JSONObject(fixtureFile.readText())
        val imported = JSONObject(File(fixtureFile.parentFile, "swift-import.json").readText())
        val origin = accountOrigin(fixture.getString("origin"))
        if (!fixture.has("certificate")) {
            require(origin == "https://halle-account-staging.gabriel-aldea.workers.dev")
            require(System.getenv("HALLE_STAGE_ORIGIN") == origin)
            runAccountStory(fixture, origin, imported)
            return
        }
        require(URI(origin).host == "127.0.0.1")
        val certificate = File(fixture.getString("certificate")).inputStream().use {
            CertificateFactory.getInstance("X.509").generateCertificate(it)
        }
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setCertificateEntry("test-worker", certificate)
        }
        val trust = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply { init(store) }
        val tls = SSLContext.getInstance("TLS").apply { init(null, trust.trustManagers, null) }
        val previousFactory = HttpsURLConnection.getDefaultSSLSocketFactory()
        try {
            HttpsURLConnection.setDefaultSSLSocketFactory(tls.socketFactory)
            runAccountStory(fixture, origin, imported)
        } finally {
            HttpsURLConnection.setDefaultSSLSocketFactory(previousFactory)
        }
    }

    private fun runAccountStory(fixture: JSONObject, origin: String, imported: JSONObject) {
        val mobile = AccountSession.from(origin, fixture.getJSONObject("mobile"))
        val stranger = AccountSession.from(origin, fixture.getJSONObject("stranger"))
        assertNotEquals(stranger.scope, mobile.scope)
        val meetingId = fixture.getString("meetingId")
        val importedId = imported.getString("meetingId")
        val importedProject = requireNotNull(AccountProject.read(imported.getJSONObject("project")))
        assertNotEquals(meetingId, importedId)
        val path = meetingPath(meetingId)
        val snapshot = AccountTransport.request(origin, snapshotPath(null), token = mobile.token)
        val original = snapshot.getJSONArray("meetings").objects()
        fun importedSelection(meetings: List<JSONObject>) = AccountProject.read(
            meetings.single { it.getString("id") == importedId }.getJSONObject("project")
        )
        assertEquals(importedProject, importedSelection(original))
        val meeting = original.single { it.getString("id") == meetingId }
        val version = snapshot.getString("version")
        assertTrue(AccountTransport.request(origin, snapshotPath(version), token = mobile.token).getBoolean("unchanged"))

        val project = requireNotNull(AccountProject.read(fixture.getJSONObject("project")))
        assertNotEquals(project.id, importedProject.id)
        val change = JSONObject(meeting.toString()).put("baseRevision", meeting.getInt("revision"))
            .put("mutationId", UUID.randomUUID().toString())
        stageProject(change, ProjectChange(project), AccountProject.read(meeting.optJSONObject("project")))
        val body = meetingRequest(change)
        repeat(2) {
            val receipt = AccountTransport.request(origin, path, "PUT", mobile.token, body).getJSONObject("meeting")
            assertTrue(projectSelectionAccepted(change, receipt))
            assertEquals(meeting.getInt("revision") + 1, receipt.getInt("revision"))
            assertEquals(project, AccountProject.read(receipt.getJSONObject("project")))
        }

        val audio = File(fixture.getString("audio"))
        val recordingId = fixture.optString("recordingId", UUID.randomUUID().toString())
        val outbox = tmp.newFile("upload.json")
        outbox.writeText(JSONObject().put("meeting", meetingId).put("provider", "deepgram").put("nextPart", 0).toString())
        fun resume(dropResponseFor: String?) {
            val state = JSONObject(outbox.readText())
            sendAccountRecording(recordingId, state, audio, { endpoint, method, json, bytes ->
                val reply = AccountTransport.request(origin, endpoint, method, mobile.token, json, bytes)
                if (dropResponseFor != null && endpoint.endsWith(dropResponseFor)) {
                    throw LostResponse(dropResponseFor)
                }
                reply
            }) { outbox.writeText(state.toString()) }
        }
        assertThrows(LostResponse::class.java) { resume("/parts/0") }
        assertEquals(0, JSONObject(outbox.readText()).getInt("nextPart"))
        assertThrows(LostResponse::class.java) { resume("/complete") }
        assertTrue(JSONObject(outbox.readText()).getInt("nextPart") > 0)
        resume(null)

        val changed = AccountTransport.request(origin, snapshotPath(version), token = mobile.token)
            .getJSONArray("meetings").objects()
        assertEquals(importedProject, importedSelection(changed))
        val edited = changed.single { it.getString("id") == meetingId }
        assertEquals(project, AccountProject.read(edited.getJSONObject("project")))
        val stored = edited.getJSONArray("recordings").objects().single { it.getString("id") == recordingId }
        val validStates = if (fixture.has("certificate")) setOf("queued") else setOf("queued", "completed", "submitting")
        assertTrue(stored.getString("status") in validStates)
        val other = AccountTransport.request(origin, "/meetings", token = stranger.token)
        assertFalse(other.getJSONArray("meetings").objects().any { it.getString("id") in setOf(meetingId, importedId) })
        val denied = assertThrows(AccountHttpError::class.java) {
            AccountTransport.request(origin, "$path/recordings/$recordingId", token = stranger.token)
        }
        assertEquals(404, denied.status)
    }

    private class LostResponse(endpoint: String) : IOException(endpoint)
}
