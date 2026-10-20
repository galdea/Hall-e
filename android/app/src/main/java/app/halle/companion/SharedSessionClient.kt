package app.halle.companion

import android.content.Context
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SharedPairingPayload(val endpoint: String, val workspaceId: String, val inviteToken: String, val workspaceKey: ByteArray)
data class SharedDevice(val id: String, val name: String, val revokedAtMs: Long?)
data class SharedSession(
    val id: String, val revision: Int, val createdAtMs: Long, val updatedAtMs: Long,
    val title: String?, val projectName: String?, val meetingUrl: String?,
    val startAtMs: Long?, val endAtMs: Long?, val decryptionFailed: Boolean,
)
data class SharedLease(
    val sessionId: String, val deviceId: String, val leaseId: String, val generation: Long,
    val generationToken: String?, val expiresAtMs: Long, val handoffRequestedDeviceId: String?,
)
data class SharedSegment(
    val id: String, val sessionId: String, val deviceId: String,
    val startedAtMs: Long, val endedAtMs: Long?, val status: String,
)
data class SharedWorkspaceState(
    val ownerDeviceId: String, val devices: List<SharedDevice>, val sessions: List<SharedSession>,
    val activeLease: SharedLease?, val segments: List<SharedSegment>,
)
data class SharedRecordingLease(
    val sessionId: String, val segmentId: String, val leaseId: String,
    val generation: Long, val generationToken: String, val localDeadlineElapsedMs: Long,
    val cancellationRequested: AtomicBoolean = AtomicBoolean(false),
)

/** HTTPS coordinator API client. It never uploads recordings or plaintext meeting payloads. */
class SharedSessionClient(context: Context) {
    private val appContext = context.applicationContext
    private val vault = SharedSessionVault(appContext)

    fun paired(): Boolean = vault.load() != null
    fun endpoint(): String = vault.load()?.endpoint ?: currentEndpoint(appContext)
    fun currentDeviceId(): String? = vault.load()?.deviceId
    fun parsePairingInput(input: String): SharedPairingPayload =
        parsePairingInput(input, currentEndpoint(appContext))

    /** Creates a workspace and returns a pairing link. The invite token is not persisted. */
    fun createWorkspace(deviceName: String): String {
        val endpoint = currentEndpoint(appContext)
        val workspaceKey = ByteArray(32).also(SecureRandom()::nextBytes)
        val response = request(endpoint, "POST", "/workspaces", null,
            JSONObject().put("deviceName", cleanDeviceName(deviceName)).toString())
        val workspaceId = response.getString("workspaceId")
        val deviceId = response.getString("deviceId")
        val token = response.getString("deviceToken")
        val inviteToken = response.getString("inviteToken")
        vault.save(Credentials(endpoint, workspaceId, deviceId, token, workspaceKey))
        return makePairingLink(endpoint, workspaceId, inviteToken, workspaceKey)
    }

    /** Owner-only; coordinator invalidates any earlier invitation when issuing a new one. */
    fun createInvitationLink(): String {
        val credentials = requireCredentials()
        val response = request(credentials.endpoint, "POST",
            "/workspaces/" + pathPart(credentials.workspaceId) + "/invites", credentials.token, "{}")
        return makePairingLink(credentials.endpoint, credentials.workspaceId,
            response.getString("inviteToken"), credentials.workspaceKey)
    }

    /** Parsing is side-effect-free; caller must confirm with the user before joining. */
    fun joinWorkspace(pairingInput: String, deviceName: String): SharedPairingPayload {
        val pairing = parsePairingInput(pairingInput)
        val response = request(pairing.endpoint, "POST", "/workspaces/" + pathPart(pairing.workspaceId) + "/join", null,
            JSONObject().put("inviteToken", pairing.inviteToken)
                .put("deviceName", cleanDeviceName(deviceName)).toString())
        val returnedWorkspace = response.getString("workspaceId")
        require(returnedWorkspace == pairing.workspaceId) { "The coordinator returned a different workspace." }
        vault.save(Credentials(pairing.endpoint, returnedWorkspace, response.getString("deviceId"),
            response.getString("deviceToken"), pairing.workspaceKey))
        return pairing
    }

    fun state(): SharedWorkspaceState {
        val credentials = requireCredentials()
        val body = request(credentials.endpoint, "GET", "/workspaces/" + pathPart(credentials.workspaceId) + "/state", credentials.token)
        val sessions = body.optJSONArray("sessions").asSequenceOfObjects().map { session ->
            val plain = runCatching {
                JSONObject(SharedSessionCrypto.decrypt(session.getString("encryptedPayload"), credentials.workspaceKey,
                    session.getString("id")).toString(StandardCharsets.UTF_8))
            }.getOrNull()
            SharedSession(
                id = session.getString("id"), revision = session.optInt("revision", 1),
                createdAtMs = session.optLong("createdAtMs"), updatedAtMs = session.optLong("updatedAtMs"),
                title = plain?.optString("title")?.takeIf(String::isNotBlank),
                projectName = plain?.optString("projectName")?.takeIf(String::isNotBlank),
                meetingUrl = plain?.optString("meetingUrl")?.takeIf(String::isNotBlank),
                startAtMs = plain?.optNullableLong("startAtMs"), endAtMs = plain?.optNullableLong("endAtMs"),
                decryptionFailed = plain == null,
            )
        }
        val devices = body.optJSONArray("devices").asSequenceOfObjects().map { device ->
            SharedDevice(device.getString("id"), device.optString("name"), device.optNullableLong("revokedAtMs"))
        }
        val leaseJson = body.optJSONObject("activeLease")
        val lease = if (leaseJson == null || leaseJson == JSONObject.NULL) null else SharedLease(
            leaseJson.getString("sessionId"), leaseJson.getString("deviceId"), leaseJson.getString("leaseId"),
            leaseJson.getLong("generation"), leaseJson.optString("generationToken").takeIf(String::isNotBlank),
            leaseJson.getLong("expiresAtMs"), leaseJson.optString("handoffRequestedDeviceId").takeIf(String::isNotBlank),
        )
        val segments = body.optJSONArray("segments").asSequenceOfObjects().map { segment ->
            SharedSegment(segment.getString("id"), segment.getString("sessionId"), segment.getString("deviceId"),
                segment.getLong("startedAtMs"), segment.optNullableLong("endedAtMs"), segment.getString("status"))
        }
        val state = SharedWorkspaceState(body.getString("ownerDeviceId"), devices, sessions, lease, segments)
        MobileMeetingStore(appContext).reconcileSharedProjects(
            sessions.filterNot { it.decryptionFailed }.associate { it.id to it.projectName },
        )
        return state
    }

    /** Publishes only the client-encrypted title/project/link/times; IDs make retries idempotent. */
    fun createSession(meeting: MobileMeeting, meetingUrl: String? = null): SharedSession {
        val credentials = requireCredentials()
        val sessionId = meeting.sharedSessionId ?: meeting.id
        require(UUID.fromString(sessionId).toString() == sessionId.lowercase()) { "Session ID must be a lowercase UUID." }
        val meetingStore = MobileMeetingStore(appContext)
        if (meeting.sharedSessionId == null && !meetingStore.setSharedSessionId(meeting.id, sessionId)) {
            throw IllegalStateException("Could not attach the shared session to the local meeting.")
        }
        state().sessions.firstOrNull { it.id == sessionId }?.let { existing ->
            check(!existing.decryptionFailed) { "The existing shared meeting could not be decrypted; it was left unchanged." }
            return existing
        }
        val payload = encryptedMeetingPayload(meeting, meetingUrl, credentials.workspaceKey, sessionId)
        val response = request(credentials.endpoint, "POST", "/workspaces/" + pathPart(credentials.workspaceId) + "/sessions",
            credentials.token, JSONObject().put("id", sessionId).put("encryptedPayload", payload).toString())
        return decryptSession(response, credentials).also { updated ->
            check(!updated.decryptionFailed) { "The new shared meeting could not be decrypted." }
        }
    }

    fun updateSessionProject(sessionId: String, projectName: String?, expectedRevision: Int): SharedSession {
        val credentials = requireCredentials()
        val normalizedProject = projectName?.trim()?.take(80)?.takeIf(String::isNotEmpty)
        val current = state().sessions.firstOrNull { it.id == sessionId } ?: error("Shared meeting not found.")
        require(!current.decryptionFailed) { "This meeting cannot be updated because its encrypted details could not be read." }
        require(current.revision == expectedRevision) { "Shared meeting changed on another device; refresh and try again." }
        val payload = JSONObject().put("v", 1).put("title", current.title ?: "Meeting")
        normalizedProject?.let { payload.put("projectName", it) }
        current.meetingUrl?.let { payload.put("meetingUrl", it) }
        payload.put("startAtMs", current.startAtMs ?: current.createdAtMs)
        current.endAtMs?.let { payload.put("endAtMs", it) }
        val encrypted = SharedSessionCrypto.encrypt(payload.toString().toByteArray(StandardCharsets.UTF_8),
            credentials.workspaceKey, sessionId)
        val response = request(credentials.endpoint, "PATCH",
            "/workspaces/" + pathPart(credentials.workspaceId) + "/sessions/" + pathPart(sessionId),
            credentials.token, JSONObject().put("encryptedPayload", encrypted).put("expectedRevision", expectedRevision).toString())
        val updated = decryptSession(response, credentials)
        check(!updated.decryptionFailed) { "The updated shared meeting could not be decrypted." }
        check(updated.projectName == normalizedProject) {
            "The shared project update could not be verified. Refresh the shared workspace before trying again."
        }
        check(MobileMeetingStore(appContext).reconcileSharedProjects(mapOf(sessionId to updated.projectName))) {
            "The shared project was updated, but this phone could not update its local meeting record. Refresh shared sessions to retry."
        }
        return updated
    }

    /** Creates lease and initial segment before the caller starts the microphone. */
    fun claimRecordingLease(sessionId: String, startedAtMs: Long = System.currentTimeMillis()): SharedRecordingLease {
        val credentials = requireCredentials()
        val requestStarted = SystemClock.elapsedRealtime()
        val claim = request(credentials.endpoint, "POST", "/workspaces/" + pathPart(credentials.workspaceId) + "/lease/claim",
            credentials.token, JSONObject().put("sessionId", sessionId).toString())
        val leaseId = claim.getString("leaseId")
        val generation = claim.getLong("generation")
        val generationToken = claim.getString("generationToken")
        val segmentId = UUID.randomUUID().toString()
        try {
            request(credentials.endpoint, "POST",
                "/workspaces/" + pathPart(credentials.workspaceId) + "/sessions/" + pathPart(sessionId) + "/segments",
                credentials.token, segmentBody(segmentId, sessionId, startedAtMs, null, "recording",
                    leaseId, generation, generationToken).toString())
        } catch (error: Exception) {
            runCatching { releaseLease(leaseId, generation, generationToken) }
            throw error
        }
        return SharedRecordingLease(sessionId, segmentId, leaseId, generation, generationToken,
            requestStarted + LEASE_CLIENT_WINDOW_MS)
    }

    /** Called only in response to a local user's explicit request to use this device. */
    fun requestHandoffToThisDevice() {
        val credentials = requireCredentials()
        request(credentials.endpoint, "POST", "/workspaces/" + pathPart(credentials.workspaceId) + "/lease/handoff",
            credentials.token, JSONObject().put("requestedDeviceId", credentials.deviceId).toString())
    }

    fun revokeDevice(deviceId: String) {
        val credentials = requireCredentials()
        request(credentials.endpoint, "DELETE",
            "/workspaces/" + pathPart(credentials.workspaceId) + "/devices/" + pathPart(deviceId),
            credentials.token)
    }

    /** Finalize metadata after local stop; release follows the finalization attempt. */
    fun finalizeSegmentAndRelease(lease: SharedRecordingLease, status: String, endedAtMs: Long = System.currentTimeMillis()): Boolean {
        require(status == "complete" || status == "interrupted")
        val credentials = requireCredentials()
        val finalized = runCatching {
            val response = request(credentials.endpoint, "PATCH",
                "/workspaces/" + pathPart(credentials.workspaceId) + "/sessions/" + pathPart(lease.sessionId)
                    + "/segments/" + pathPart(lease.segmentId),
                credentials.token, segmentBody(lease.segmentId, lease.sessionId, null, endedAtMs, status,
                    lease.leaseId, lease.generation, lease.generationToken).toString())
            response.optString("id") == lease.segmentId
        }.getOrDefault(false)
        val released = runCatching {
            request(credentials.endpoint, "POST", "/workspaces/" + pathPart(credentials.workspaceId) + "/lease/release",
                credentials.token, JSONObject().put("leaseId", lease.leaseId).put("generation", lease.generation)
                    .put("generationToken", lease.generationToken).toString()).optBoolean("released", false)
        }.getOrDefault(false)
        return finalized && released
    }

    /** Renewal/deadline loop. Its callback only requests a local stop; it never starts a recorder. */
    fun renewWhileRecording(lease: SharedRecordingLease, guard: LeaseDeadline, onStopRequired: () -> Unit): AutoCloseable {
        val credentials = requireCredentials()
        val stopIssued = AtomicBoolean(false)
        val stopOnce = { if (stopIssued.compareAndSet(false, true)) onStopRequired() }
        val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "halle-shared-lease").apply { isDaemon = true }
        }
        val task: ScheduledFuture<*> = executor.scheduleWithFixedDelay({
            if (!guard.isValid()) {
                stopOnce()
                return@scheduleWithFixedDelay
            }
            val requestStarted = SystemClock.elapsedRealtime()
            val proposedDeadline = requestStarted + LEASE_CLIENT_WINDOW_MS
            guard.tighten(proposedDeadline)
            try {
                val response = request(credentials.endpoint, "POST",
                    "/workspaces/" + pathPart(credentials.workspaceId) + "/lease/renew",
                    credentials.token, JSONObject().put("leaseId", lease.leaseId).put("generation", lease.generation)
                        .put("generationToken", lease.generationToken).toString())
                if (SystemClock.elapsedRealtime() >= guard.deadlineElapsedMs) stopOnce()
                else if (response.optBoolean("handoffRequested", false)) {
                    guard.expire()
                    stopOnce()
                } else guard.extendTo(proposedDeadline)
            } catch (_: Exception) {
                // Failed renewal never extends the last confirmed deadline.
            }
        }, LEASE_RENEW_INTERVAL_MS, LEASE_RENEW_INTERVAL_MS, TimeUnit.MILLISECONDS)
        return AutoCloseable { task.cancel(true); executor.shutdownNow() }
    }

    fun leaveWorkspace() {
        require(!recordingPreparationActive()) { "Wait until this phone finishes preparing its recording before leaving the shared workspace." }
        require(MobileMeetingStore(appContext).activeRecording() == null) {
            "Stop this phone's active recording before leaving the shared workspace."
        }
        val credentials = requireCredentials()
        request(credentials.endpoint, "POST", "/workspaces/" + pathPart(credentials.workspaceId) + "/leave", credentials.token, "{}")
        vault.clear()
    }

    private fun releaseLease(leaseId: String, generation: Long, generationToken: String) {
        val credentials = requireCredentials()
        request(credentials.endpoint, "POST", "/workspaces/" + pathPart(credentials.workspaceId) + "/lease/release",
            credentials.token, JSONObject().put("leaseId", leaseId).put("generation", generation)
                .put("generationToken", generationToken).toString())
    }

    private fun decryptSession(response: JSONObject, credentials: Credentials): SharedSession {
        val id = response.getString("id")
        val plain = runCatching {
            JSONObject(SharedSessionCrypto.decrypt(response.getString("encryptedPayload"), credentials.workspaceKey, id).toString(StandardCharsets.UTF_8))
        }.getOrNull()
        return SharedSession(id, response.optInt("revision", 1), response.optLong("createdAtMs"), response.optLong("updatedAtMs"),
            plain?.optString("title")?.takeIf(String::isNotBlank), plain?.optString("projectName")?.takeIf(String::isNotBlank),
            plain?.optString("meetingUrl")?.takeIf(String::isNotBlank), plain?.optNullableLong("startAtMs"),
            plain?.optNullableLong("endAtMs"), plain == null)
    }

    private fun encryptedMeetingPayload(meeting: MobileMeeting, meetingUrl: String?, key: ByteArray, sessionId: String): String {
        val payload = JSONObject().put("v", 1).put("title", meeting.title)
        meeting.projectName?.let { payload.put("projectName", it) }
        meetingUrl?.takeIf(String::isNotBlank)?.let { payload.put("meetingUrl", it) }
        payload.put("startAtMs", meeting.scheduledStartAtMs ?: meeting.createdAtMs)
        meeting.scheduledEndAtMs?.let { payload.put("endAtMs", it) }
        return SharedSessionCrypto.encrypt(payload.toString().toByteArray(StandardCharsets.UTF_8), key, sessionId)
    }

    private fun segmentBody(
        id: String, sessionId: String, startedAtMs: Long?, endedAtMs: Long?, status: String,
        leaseId: String, generation: Long, generationToken: String,
    ): JSONObject = JSONObject().apply {
        put("id", id); put("sessionId", sessionId)
        if (startedAtMs != null) put("startedAtMs", startedAtMs)
        if (endedAtMs != null) put("endedAtMs", endedAtMs) else put("endedAtMs", JSONObject.NULL)
        put("status", status); put("leaseId", leaseId); put("generation", generation); put("generationToken", generationToken)
    }

    private fun requireCredentials(): Credentials = vault.load() ?: error("This device is not paired to a shared workspace.")

    private fun request(endpoint: String, method: String, path: String, token: String? = null, jsonBody: String? = null): JSONObject {
        val url = URL(validateEndpoint(endpoint, BuildConfig.DEBUG) + "/v1" + path)
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = HTTP_TIMEOUT_MS
            readTimeout = HTTP_TIMEOUT_MS
            instanceFollowRedirects = false
            setRequestProperty("Accept", "application/json")
            if (token != null) setRequestProperty("Authorization", "Bearer " + token)
            if (jsonBody != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }
        }
        return try {
            if (jsonBody != null) {
                val bytes = jsonBody.toByteArray(StandardCharsets.UTF_8)
                require(bytes.size <= MAX_REQUEST_BYTES) { "Coordinator request is too large." }
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val bytes = stream?.let { readLimited(it, MAX_RESPONSE_BYTES) } ?: ByteArray(0)
            val response = if (bytes.isEmpty()) JSONObject() else JSONObject(String(bytes, StandardCharsets.UTF_8))
            if (status !in 200..299) throw SharedCoordinatorException(status, response.optString("error", "coordinator_error"))
            response
        } finally { connection.disconnect() }
    }

    private fun readLimited(stream: java.io.InputStream, limit: Int): ByteArray = BufferedInputStream(stream).use { input ->
        val output = ByteArrayOutputStream(); val buffer = ByteArray(2048)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= limit) { "Coordinator response is too large." }
            output.write(buffer, 0, count)
        }
        output.toByteArray()
    }

    private fun cleanDeviceName(value: String): String = value.trim().take(80).ifBlank { "Android device" }
    private fun pathPart(value: String): String {
        require(value.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "Invalid coordinator identifier." }
        return value
    }

    companion object {
        const val PRODUCTION_ENDPOINT = "https://halle-shared-session-coordinator.gabriel-aldea.workers.dev"
        const val PAIRING_PAGE = "https://hall-e.pages.dev/pair"
        private const val DEBUG_ENDPOINT_PREFS = "shared-session-debug"
        private const val KEY_ENDPOINT = "endpoint"
        private const val HTTP_TIMEOUT_MS = 8_000
        private const val MAX_REQUEST_BYTES = 16 * 1024
        private const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024
        private const val LEASE_CLIENT_WINDOW_MS = 15_000L
        private const val LEASE_RENEW_INTERVAL_MS = 5_000L
        private val recordingPreparation = AtomicBoolean(false)

        fun beginRecordingPreparation(): Boolean = recordingPreparation.compareAndSet(false, true)
        fun finishRecordingPreparation() { recordingPreparation.set(false) }
        fun recordingPreparationActive(): Boolean = recordingPreparation.get()

        fun setDebugEndpoint(context: Context, candidate: String) {
            check(BuildConfig.DEBUG) { "Coordinator endpoint override is debug-only." }
            val endpoint = validateEndpoint(candidate, true)
            context.applicationContext.getSharedPreferences(DEBUG_ENDPOINT_PREFS, Context.MODE_PRIVATE)
                .edit().putString(KEY_ENDPOINT, endpoint).apply()
        }

        fun currentEndpoint(context: Context): String {
            if (BuildConfig.DEBUG) {
                val override = context.applicationContext.getSharedPreferences(DEBUG_ENDPOINT_PREFS, Context.MODE_PRIVATE)
                    .getString(KEY_ENDPOINT, null)
                if (override != null) return validateEndpoint(override, true)
            }
            return PRODUCTION_ENDPOINT
        }

        fun parsePairingInput(input: String, expectedEndpoint: String): SharedPairingPayload {
            val raw = input.trim()
            val encoded = when {
                raw.startsWith("https://", ignoreCase = true) -> {
                    val uri = URI(raw)
                    require(uri.scheme == "https" && uri.host == "hall-e.pages.dev" && uri.path == "/pair"
                        && uri.userInfo == null && uri.port == -1 && uri.rawQuery == null) { "Unsupported pairing link." }
                    uri.rawFragment ?: error("Pairing link has no invite fragment.")
                }
                raw.startsWith("halle://pair?", ignoreCase = true) -> {
                    val uri = URI(raw)
                    require(uri.host == "pair" && uri.path.isNullOrEmpty() && uri.userInfo == null) { "Unsupported pairing link." }
                    uri.rawQuery.split('&').firstNotNullOfOrNull { part ->
                        val pair = part.split('=', limit = 2)
                        if (pair.getOrNull(0) == "payload") pair.getOrNull(1) else null
                    } ?: error("Pairing link has no payload.")
                }
                else -> raw
            }
            val json = JSONObject(String(Base64.getUrlDecoder().decode(encoded), StandardCharsets.UTF_8))
            require(json.getInt("v") == 1) { "Unsupported pairing code version." }
            val endpoint = validateEndpoint(json.getString("endpoint"), BuildConfig.DEBUG)
            require(endpoint == validateEndpoint(expectedEndpoint, BuildConfig.DEBUG)) { "Pairing link uses an unapproved coordinator." }
            val key = Base64.getUrlDecoder().decode(json.getString("key"))
            require(key.size == 32) { "Invalid pairing encryption key." }
            val invite = json.getString("inviteToken")
            require(invite.length in 32..128) { "Invalid pairing invitation." }
            val workspace = json.getString("workspaceId")
            require(workspace.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "Invalid workspace ID." }
            return SharedPairingPayload(endpoint, workspace, invite, key)
        }

        fun makePairingLink(endpoint: String, workspaceId: String, inviteToken: String, workspaceKey: ByteArray): String {
            require(workspaceKey.size == 32)
            require(workspaceId.matches(Regex("[A-Za-z0-9_-]{1,128}")))
            val payload = JSONObject().put("v", 1).put("endpoint", validateEndpoint(endpoint, BuildConfig.DEBUG))
                .put("workspaceId", workspaceId).put("inviteToken", inviteToken)
                .put("key", Base64.getUrlEncoder().withoutPadding().encodeToString(workspaceKey))
            val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(payload.toString().toByteArray(StandardCharsets.UTF_8))
            return PAIRING_PAGE + "#" + encoded
        }

        internal fun validateStoredEndpoint(endpoint: String): String = validateEndpoint(endpoint, BuildConfig.DEBUG)

        private fun validateEndpoint(raw: String, debug: Boolean): String {
            val uri = URI(raw.trim())
            require(uri.userInfo == null && uri.rawQuery == null && uri.rawFragment == null
                && (uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")) { "Invalid coordinator endpoint." }
            val host = uri.host?.lowercase() ?: error("Coordinator endpoint needs a host.")
            val productionHost = URI(PRODUCTION_ENDPOINT).host.lowercase()
            val loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
            require((uri.scheme == "https" && (host == productionHost || (debug && loopback)))
                || (debug && uri.scheme == "http" && loopback)) { "Coordinator host is not allowlisted." }
            require(uri.port == -1 || (debug && loopback && uri.port in 1..65535)) { "Coordinator port is not allowed." }
            return URI(uri.scheme.lowercase(), null, host, uri.port, null, null, null).toString().removeSuffix("/")
        }
    }
}

/** Monotonic lease deadline. Failed renewals never move it forward. */
class LeaseDeadline(
    initialDeadlineElapsedMs: Long,
    private val nowElapsed: () -> Long = { SystemClock.elapsedRealtime() },
) {
    @Volatile var deadlineElapsedMs: Long = initialDeadlineElapsedMs
        private set
    fun isValid(): Boolean = nowElapsed() < deadlineElapsedMs
    @Synchronized fun tighten(proposed: Long) { deadlineElapsedMs = minOf(deadlineElapsedMs, proposed) }
    @Synchronized fun extendTo(confirmed: Long) {
        if (nowElapsed() < deadlineElapsedMs) deadlineElapsedMs = confirmed
    }
    @Synchronized fun expire() { deadlineElapsedMs = 0 }
}

class SharedCoordinatorException(val httpStatus: Int, val code: String) :
    IllegalStateException("Coordinator request failed (" + httpStatus + ": " + code + ").")

object SharedSessionCrypto {
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128

    fun encrypt(plaintext: ByteArray, key: ByteArray, sessionId: String): String {
        require(key.size == 32)
        val nonce = ByteArray(NONCE_BYTES).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(("session:" + sessionId).toByteArray(StandardCharsets.UTF_8))
        return Base64.getEncoder().encodeToString(nonce + cipher.doFinal(plaintext))
    }

    fun decrypt(encryptedPayload: String, key: ByteArray, sessionId: String): ByteArray {
        require(key.size == 32)
        val packed = Base64.getDecoder().decode(encryptedPayload)
        require(packed.size >= NONCE_BYTES + TAG_BITS / 8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAG_BITS, packed.copyOfRange(0, NONCE_BYTES)))
        cipher.updateAAD(("session:" + sessionId).toByteArray(StandardCharsets.UTF_8))
        return cipher.doFinal(packed.copyOfRange(NONCE_BYTES, packed.size))
    }
}

private data class Credentials(
    val endpoint: String, val workspaceId: String, val deviceId: String,
    val token: String, val workspaceKey: ByteArray,
)

private class SharedSessionVault(private val context: Context) {
    fun save(credentials: Credentials) {
        val raw = JSONObject().put("endpoint", credentials.endpoint).put("workspaceId", credentials.workspaceId)
            .put("deviceId", credentials.deviceId).put("token", credentials.token)
            .put("workspaceKey", Base64.getEncoder().encodeToString(credentials.workspaceKey))
            .toString().toByteArray(StandardCharsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encoded = Base64.getEncoder().encodeToString(cipher.iv + cipher.doFinal(raw))
        check(context.getSharedPreferences(VAULT_PREFS, Context.MODE_PRIVATE).edit().putString(VAULT_KEY, encoded).commit()) {
            "Could not protect the shared workspace credentials."
        }
    }

    fun load(): Credentials? {
        val encoded = context.getSharedPreferences(VAULT_PREFS, Context.MODE_PRIVATE).getString(VAULT_KEY, null) ?: return null
        return runCatching {
            val packed = Base64.getDecoder().decode(encoded)
            require(packed.size > IV_BYTES + 16)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, packed.copyOfRange(0, IV_BYTES)))
            val json = JSONObject(String(cipher.doFinal(packed.copyOfRange(IV_BYTES, packed.size)), StandardCharsets.UTF_8))
            val endpoint = SharedSessionClient.validateStoredEndpoint(json.getString("endpoint"))
            Credentials(endpoint, json.getString("workspaceId"), json.getString("deviceId"), json.getString("token"),
                Base64.getDecoder().decode(json.getString("workspaceKey")).also { require(it.size == 32) })
        }.getOrNull()
    }

    fun clear() { context.getSharedPreferences(VAULT_PREFS, Context.MODE_PRIVATE).edit().remove(VAULT_KEY).commit() }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }

    companion object {
        private const val VAULT_PREFS = "shared-session-credentials"
        private const val VAULT_KEY = "credentials"
        private const val KEY_ALIAS = "halle.shared.session.credentials.v1"
        private const val IV_BYTES = 12
    }
}

private fun JSONArray?.asSequenceOfObjects(): List<JSONObject> = buildList {
    val array = this@asSequenceOfObjects ?: return@buildList
    for (index in 0 until array.length()) array.optJSONObject(index)?.let(::add)
}
private fun JSONObject.optNullableLong(name: String): Long? = if (!has(name) || isNull(name)) null else optLong(name)
