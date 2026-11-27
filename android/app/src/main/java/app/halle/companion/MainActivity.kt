package app.halle.companion

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.CalendarContract
import android.provider.Settings
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

/**
 * Órbita home: the packaged Imba renderer in a locked-down WebView. Microphone, calendar, files, accounts and
 * credentials stay native. Every store or file read/write a bridge action triggers runs on [io]; the UI thread
 * only shows dialogs, starts activities and pushes snapshots into the page.
 */
class MainActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var store: LocalStore
    private lateinit var meetings: MobileMeetingStore
    private lateinit var calendar: CalendarRepository
    private val handler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "halle-orbita-io") }
    private var foreground = false
    private var ready = false
    private var preview = false
    private var reminderRegistered = false
    private var previousBrightness: Float? = null
    private var player: MediaPlayer? = null
    private var micAskedBefore = false
    private var pollGeneration = 0

    // Written on the UI thread, read by snapshots built on io.
    @Volatile private var pendingStartId: String? = null
    @Volatile private var paired = false
    @Volatile private var calendarEvents: List<MeetingOccurrence> = emptyList()
    @Volatile private var rangeDate: LocalDate = LocalDate.now()
    @Volatile private var activeStatus: MobileMeetingStatus? = null

    // Recording startup (UI thread only).
    private var pendingStartAt = 0L
    private var serviceRequested = false
    private var leaseAcquiring = false
    private var heldLease: SharedRecordingLease? = null
    private var preparationHeld = false

    // io thread only.
    private var lastSnapshot = ""

    private val resetReminder = Runnable {
        previousBrightness?.let { old -> window.attributes = window.attributes.apply { screenBrightness = old } }
        previousBrightness = null
        if (ready) web.evaluateJavascript("document.documentElement.classList.remove('recording-reminder')", null)
    }
    private val reminderReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != RecordingScreenReminder.ACTION_REMINDER || !foreground || preview ||
                activeStatus != MobileMeetingStatus.RECORDING) return
            if (previousBrightness == null) previousBrightness = window.attributes.screenBrightness
            handler.removeCallbacks(resetReminder)
            window.attributes = window.attributes.apply { screenBrightness = 1f }
            if (ready) web.evaluateJavascript("window.hallEReminder?.()", null)
            handler.postDelayed(resetReminder, RecordingScreenReminder.PULSE_DURATION_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = BACKGROUND; window.navigationBarColor = BACKGROUND
        WindowCompat.getInsetsController(window, window.decorView).apply { isAppearanceLightStatusBars = false; isAppearanceLightNavigationBars = false }
        preview = BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_PREVIEW, false)
        store = LocalStore(this); meetings = MobileMeetingStore(this); calendar = CalendarRepository(this, store)
        if (BuildConfig.DEBUG) store.previewActive = preview
        if (!preview) io.execute {
            meetings.recoverInterrupted()
            PermissionPrompts(this).asked(Manifest.permission.RECORD_AUDIO) // loads the prompt flags off the UI thread
            // Órbita previews remembered the notification prompt separately; carry that answer over so it is asked once.
            if (getSharedPreferences(LEGACY_ORBITA_PROMPTS, MODE_PRIVATE).getBoolean("notificationsAsked", false))
                PermissionPrompts(this).markAsked(Manifest.permission.POST_NOTIFICATIONS)
        }
        web = WebView(this).apply { setBackgroundColor(BACKGROUND) }
        web.settings.apply {
            javaScriptEnabled = true; allowFileAccess = false; allowContentAccess = false; domStorageEnabled = false
            setSupportMultipleWindows(false); javaScriptCanOpenWindowsAutomatically = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW; mediaPlaybackRequiresUserGesture = true
            // Follow Android's font size setting like the native screens do.
            textZoom = OrbitaBridgePolicy.textZoom(resources.configuration.fontScale)
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest): WebResourceResponse {
                val path = request.url.path.orEmpty()
                val mime = when (path) { "/index.html" -> "text/html"; "/app.js" -> "application/javascript"; "/app.css" -> "text/css"; "/hall-e.webp", "/hall-e-heart.webp", "/hal.webp", "/wall-e.webp" -> "image/webp"; else -> null }
                if (request.url.scheme != "https" || request.url.host != ASSET_HOST || request.method != "GET" || mime == null)
                    return WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
                return WebResourceResponse(mime, "UTF-8", assets.open("orbita" + path))
            }
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest): Boolean = true
            override fun onPageFinished(view: WebView?, url: String?) { if (url == ASSET_URL) { ready = true; publish(true) } }
        }
        // An explicit debug preview gets only the browser's synthetic local model.
        if (!preview) web.addJavascriptInterface(Bridge(), "HallENative")
        // WebView ignores padding for its document viewport; inset its parent instead.
        val content = FrameLayout(this).apply {
            setBackgroundColor(BACKGROUND)
            addView(web, FrameLayout.LayoutParams(-1, -1))
        }
        setContentView(content)
        ViewCompat.setOnApplyWindowInsetsListener(content) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars()); val keyboard = insets.getInsets(WindowInsetsCompat.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, keyboard.bottom)); insets
        }
        ViewCompat.requestApplyInsets(content); web.loadUrl(ASSET_URL); consumeIntent(intent)
    }

    override fun onResume() {
        super.onResume(); foreground = true
        if (preview) return
        // Finishes moving a deleted account's phone recordings into this library after an interruption.
        AccountRecordingMoves.resumeAsync(this) { runOnUiThread { if (!isFinishing && !isDestroyed) publish(true) } }
        ContextCompat.registerReceiver(this, reminderReceiver, IntentFilter(RecordingScreenReminder.ACTION_REMINDER), ContextCompat.RECEIVER_NOT_EXPORTED)
        reminderRegistered = true
        refreshCalendar(); refreshReminders(); maybeShowMorningSummary()
        pendingStartId?.let { if (!serviceRequested && !leaseAcquiring && microphoneGranted()) startCapture(it) }
        pollGeneration++; handler.removeCallbacks(poll); handler.post(poll)
    }

    override fun onPause() {
        foreground = false; pollGeneration++; handler.removeCallbacks(poll); handler.removeCallbacks(resetReminder); resetReminder.run()
        if (reminderRegistered) { unregisterReceiver(reminderReceiver); reminderRegistered = false }
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); consumeIntent(intent) }

    private fun consumeIntent(source: Intent) {
        if (preview) return
        source.getStringExtra(EXTRA_START_RECORDING)?.let { id ->
            source.removeExtra(EXTRA_START_RECORDING)
            // A shared-session handoff only prompts; this user still chooses to record here.
            background({ meetings.find(id) }) { meeting ->
                if (meeting == null || meeting.status != MobileMeetingStatus.DRAFT) return@background
                AlertDialog.Builder(this).setTitle("¿Grabar con este teléfono?")
                    .setMessage("Hall-e graba solo con el micrófono de este teléfono. Puede que no capte a participantes remotos y grabar puede requerir el consentimiento de todos.")
                    .setPositiveButton("Grabar") { _, _ -> requestCapture(meeting.id) }
                    .setNegativeButton("Ahora no", null).show()
            }
        }
        source.getLongExtra(MeetingAlertReceiver.EXTRA_BEGIN, 0).takeIf { it > 0 }?.let {
            rangeDate = Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault()).toLocalDate(); refreshCalendar()
        }
    }

    inner class Bridge {
        @JavascriptInterface fun dispatch(action: String, raw: String) {
            if (!OrbitaBridgePolicy.accepts(action, raw)) return
            val p = runCatching { JSONObject(raw) }.getOrNull() ?: return
            runOnUiThread { if (!isFinishing && ready && !preview) runCatching { handle(action, p) }.onFailure { showError(it.message ?: GENERIC_ERROR) } }
        }
    }

    private fun handle(action: String, p: JSONObject) {
        if (OrbitaBridgePolicy.blockedInStaging(action, BuildConfig.STAGING)) { showError(OrbitaBridgePolicy.STAGING_PAIRING_NOTE); return }
        when (action) {
            "refresh" -> { publish(true); refreshCalendar() }
            "range" -> { rangeDate = LocalDate.parse(p.getString("date")); refreshCalendar() }
            "quickRecord" -> quickRecord()
            "recordMeeting" -> recordMeeting(p.getString("id"))
            "stop" -> background({ meetings.activeRecording()?.id }) { id ->
                id?.let { MeetingRecordingService.requestStop(this, it, "user") }
                handler.postDelayed({ publish(true) }, 500)
            }
            "updateMeeting" -> {
                val id = p.getString("id"); val title = p.optString("title").trim(); val project = p.optString("project").trim().takeIf(String::isNotBlank)
                background({
                    val previous = meetings.find(id) ?: error("La reunión ya no está disponible.")
                    if (title.isNotBlank() && title != previous.title) check(meetings.updateTitle(id, title)) { "No se pudo guardar el nombre." }
                    if (project != previous.projectName) check(meetings.updateProject(id, project)) { "No se pudo guardar el proyecto." }
                }) { publish(true); message("Detalles guardados.") }
            }
            "createProject" -> { val name = p.getString("name"); background({ check(store.addProject(name).isNotBlank()) }) { publish(true) } }
            "schedule" -> {
                val at = LocalDate.parse(p.getString("date")).atTime(LocalTime.parse(p.getString("time"))).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                val title = p.optString("title").ifBlank { "Nueva reunión" }; val project = p.optString("project").takeIf(String::isNotBlank)
                background({ meetings.createDraft(title, project, null, at, at + 3_600_000) }) { draft ->
                    publish(true); refreshReminders(); maybeRequestNotifications(); shareDraftIfPaired(draft)
                }
            }
            "trash" -> {
                val id = p.getString("id"); val external = p.optBoolean("calendar")
                check(id != pendingStartId) { "Espera a que comience la grabación y luego detenla antes de eliminarla." }
                background({ if (external) check(store.hideOccurrence(id.removePrefix("calendar:"), true)) else setLocalTrashed(id, true) }) {
                    refreshReminders()
                    result(JSONObject().put("trash", JSONObject().put("id", id).put("calendar", external))); publish(true)
                }
            }
            "restore" -> {
                val id = p.getString("id"); val external = p.optBoolean("calendar")
                background({ if (external) check(store.hideOccurrence(id.removePrefix("calendar:"), false)) else setLocalTrashed(id, false) }) {
                    refreshReminders(); publish(true)
                }
            }
            "deleteMeeting" -> deleteMeeting(p.getString("id"))
            "assignProject" -> {
                val e = eventFor(p.getString("id")) ?: error("Actualiza el calendario y vuelve a intentarlo.")
                val project = p.optString("project").trim().takeIf(String::isNotBlank)
                background({ store.assignProject(e.eventKey, project) }) { publish(true); message("Proyecto guardado.") }
            }
            "openEvent" -> {
                val e = eventFor(p.getString("id")) ?: error("Actualiza el calendario y vuelve a intentarlo.")
                runCatching {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.withAppendedPath(CalendarContract.Events.CONTENT_URI, e.eventId.toString()))
                        .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, e.beginMillis).putExtra(CalendarContract.EXTRA_EVENT_END_TIME, e.endMillis))
                }.onFailure { showError("No hay una app de calendario disponible.") }
            }
            "testNotification" -> sendTestNotification()
            "play" -> play(p.getString("id"))
            "shareAudio" -> {
                val id = p.getString("id")
                background({ meetings.shareIntent(id) ?: meetings.sharePartialFileIntent(id) ?: error("El audio ya no está en este teléfono.") }) { share ->
                    startActivity(Intent.createChooser(share, "Compartir audio"))
                }
            }
            "join" -> {
                val e = eventFor(p.getString("id")) ?: error("Actualiza el calendario y vuelve a intentarlo.")
                val link = e.meetingUrl ?: error("Esta reunión no tiene enlace.")
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)))
            }
            "note" -> editNote(p.getString("id"))
            "scanQr" -> startActivityForResult(Intent(this, SharedSessionActivity::class.java)
                .putExtra(SharedSessionActivity.EXTRA_SCAN_ON_LAUNCH, true), SHARED_SESSION_SCAN_REQUEST)
            "pair" -> startActivity(Intent(this, SharedSessionActivity::class.java))
            "accountCalendar" -> startActivity(Intent(this, AccountCalendarActivity::class.java)
                .putExtra(AccountCalendarActivity.EXTRA_DAY, OrbitaBridgePolicy.accountCalendarDay(p.optString("date"), rangeDate)))
            "calendarAccess" -> if (calendar.hasPermission()) chooseCalendars() else requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), CALENDAR_PERMISSION)
            "reminders" -> chooseReminders()
            "notifications" -> maybeRequestNotifications(force = true)
            "exactAlarms" -> startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
            "trashList" -> showTrash()
        }
    }

    /** Runs store/file work on [io], then [ui] on the UI thread; a failure shows its (Spanish) message. */
    private fun <T> background(work: () -> T, onError: (Throwable) -> Unit = {}, ui: (T) -> Unit) {
        io.execute {
            val outcome = runCatching(work)
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                outcome.onSuccess { runCatching { ui(it) }.onFailure { showError(it.message ?: GENERIC_ERROR) } }
                    .onFailure { onError(it); showError(it.message ?: GENERIC_ERROR) }
            }
        }
    }

    // --- Recording -------------------------------------------------------------------------------------------

    private fun quickRecord() {
        if (preview || !foreground) return
        if (pendingStartId != null) { showError(BUSY); publish(true); return }
        background({
            if (meetings.activeRecording() != null || SharedSessionClient.recordingPreparationActive()) null
            else meetings.createDraft("Reunión instantánea", null, null, System.currentTimeMillis(), null)
        }) { draft -> if (draft == null) { showError(BUSY); publish(true) } else requestCapture(draft.id) }
    }

    private fun recordMeeting(id: String) {
        if (preview || !foreground) return
        if (pendingStartId != null) { showError(BUSY); publish(true); return }
        val event = if (id.startsWith("calendar:")) calendarEvents.find { "calendar:" + it.occurrenceId == id }
            ?: error("Actualiza el calendario y vuelve a intentarlo.") else null
        background({
            if (meetings.activeRecording() != null || SharedSessionClient.recordingPreparationActive()) return@background null
            if (event != null) meetings.createDraft(event.title, store.projectFor(event.eventKey), event.occurrenceId, event.beginMillis, event.endMillis).id
            else {
                val m = meetings.find(id) ?: error("La reunión ya no está disponible.")
                check(m.trashedAtMs == null) { "La reunión está en la papelera." }
                check(m.status == MobileMeetingStatus.DRAFT) { "Esta reunión ya tiene una grabación." }
                id
            }
        }) { draftId -> if (draftId == null) { showError(BUSY); publish(true) } else requestCapture(draftId) }
    }

    /** One request asks for the microphone and, once, notifications; recording starts whatever the notification answer. */
    private fun requestCapture(id: String) {
        if (preview || !foreground) return
        pendingStartId = id; pendingStartAt = SystemClock.elapsedRealtime(); serviceRequested = false
        val request = prepareRecordingPermissions()
        if (request.permissions.isNotEmpty()) {
            micAskedBefore = request.microphoneAskedBefore
            requestPermissions(request.permissions, MIC_PERMISSION)
        } else startCapture(id)
        publish(true)
    }

    /** Paired phones claim the workspace's exclusive recording lease first, as the native home screen did. */
    private fun startCapture(id: String) {
        if (preview || !foreground || serviceRequested || leaseAcquiring) return
        val client = SharedSessionClient(this)
        leaseAcquiring = true
        background({
            // Staging never reaches the production pairing coordinator.
            if (BuildConfig.STAGING || !client.paired()) return@background null
            check(SharedSessionClient.beginRecordingPreparation()) { "Ya se está preparando una grabación compartida en este teléfono." }
            runCatching {
                val meeting = meetings.find(id) ?: error("La reunión ya no está disponible.")
                val sessionId = meeting.sharedSessionId ?: meeting.id
                if (client.state().sessions.none { it.id == sessionId }) client.createSession(meeting)
                client.claimRecordingLease(sessionId)
            }.getOrElse { SharedSessionClient.finishRecordingPreparation(); throw it }
        }, onError = {
            leaseAcquiring = false
            if (pendingStartId == id) { pendingStartId = null; publish(true) }
        }) { lease ->
            leaseAcquiring = false
            if (lease != null) { preparationHeld = true; heldLease = lease }
            if (!foreground || pendingStartId != id) {
                releaseStartup(cancelled = true)
                if (lease != null) showError("La grabación no comenzó porque Hall-e dejó de estar en primer plano.")
                return@background
            }
            startService(id, lease)
        }
    }

    private fun startService(id: String, lease: SharedRecordingLease?) {
        serviceRequested = true; pendingStartAt = SystemClock.elapsedRealtime()
        val deadline = lease?.let { LeaseDeadline(it.localDeadlineElapsedMs) }
        background({ MeetingRecordingService.start(this, id, deadline?.let { guard -> { guard.isValid() } }, lease) }) { started ->
            if (!started) {
                // The service never took the lease, so it is finalized here.
                serviceRequested = false
                releaseStartup(cancelled = true)
                pendingStartId = null
                showError("No se pudo iniciar el micrófono. La reunión está guardada.")
                publish(true)
            }
        }
    }

    /** Ends lease preparation; a lease that never reached a running recorder is finalized as interrupted. */
    private fun releaseStartup(cancelled: Boolean) {
        val lease = heldLease
        if (preparationHeld) SharedSessionClient.finishRecordingPreparation()
        preparationHeld = false; heldLease = null
        if (cancelled && lease != null) {
            if (serviceRequested) lease.cancellationRequested.set(true)
            else io.execute { runCatching { SharedSessionClient(this).finalizeSegmentAndRelease(lease, "interrupted") } }
        }
    }

    private fun checkStartup(id: String, status: MobileMeetingStatus?) {
        if (pendingStartId != id || leaseAcquiring) return
        if (status == MobileMeetingStatus.RECORDING) { pendingStartId = null; serviceRequested = false; releaseStartup(cancelled = false); return }
        if (!serviceRequested) return
        if (status == MobileMeetingStatus.FAILED || status == MobileMeetingStatus.INTERRUPTED ||
            SystemClock.elapsedRealtime() - pendingStartAt > STARTUP_TIMEOUT_MS) {
            releaseStartup(cancelled = true)
            MeetingRecordingService.requestStop(this, id, "startup-timeout")
            pendingStartId = null; serviceRequested = false
            showError("Android no confirmó el inicio del micrófono. La captura se detuvo de forma segura.")
        }
    }

    private fun microphoneGranted() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private val poll = object : Runnable {
        override fun run() {
            if (!foreground) return
            val generation = pollGeneration
            val pending = pendingStartId
            io.execute {
                val active = runCatching { meetings.activeRecording() }.getOrNull()
                val pendingStatus = pending?.let { runCatching { meetings.find(it)?.status }.getOrNull() }
                runOnUiThread {
                    if (generation != pollGeneration || !foreground || isFinishing) return@runOnUiThread
                    activeStatus = active?.status
                    pending?.let { checkStartup(it, pendingStatus) }
                    if (active?.status == MobileMeetingStatus.RECORDING) maybeRequestNotifications()
                    publish()
                    handler.postDelayed(this, if (active != null || pendingStartId != null) 250 else 1500)
                }
            }
        }
    }

    // --- Library ---------------------------------------------------------------------------------------------

    private class DeleteCandidate(val meeting: MobileMeeting, val actions: List<PhoneRecordingAction>)

    private fun deleteCandidate(id: String): DeleteCandidate {
        val meeting = meetings.find(id) ?: error("La reunión ya no está disponible.")
        return DeleteCandidate(meeting, actionsFor(meeting))
    }

    /** Permanent delete from this phone, under [PhoneRecordingPolicy]: never while recording, drafts included. */
    private fun deleteMeeting(id: String, confirmed: Boolean = true) {
        if (id == pendingStartId) { showError("Espera a que comience la grabación y luego detenla antes de eliminarla."); return }
        background({ deleteCandidate(id) }) { candidate ->
            check(PhoneRecordingAction.DELETE in candidate.actions) { "Detén la grabación antes de eliminarla." }
            if (!confirmed) { confirmDelete(candidate); return@background }
            performDelete(candidate.meeting)
        }
    }

    private fun confirmDelete(candidate: DeleteCandidate) {
        val m = candidate.meeting
        AlertDialog.Builder(this).setTitle(personalDeleteTitleEs(m.status))
            .setMessage(personalDeleteMessageEs(m.title, hasAudio(candidate.actions), sharedSession = m.sharedSessionId != null))
            .setNegativeButton("Cancelar", null)
            .setPositiveButton("Eliminar") { _, _ -> performDelete(m) }.show()
    }

    private fun performDelete(m: MobileMeeting) {
        if (player != null && playingId == m.id) { player?.release(); player = null; playingId = null }
        background({ meetings.deleteRecording(m.id) }) { deleted ->
            if (deleted) result(JSONObject().put("deleted", JSONObject().put("id", m.id)))
            message(personalDeletedMessageEs(m.status, deleted))
            refreshReminders(); publish(true)
        }
    }

    private fun hasAudio(actions: List<PhoneRecordingAction>) =
        PhoneRecordingAction.PLAY in actions || PhoneRecordingAction.SHARE_PARTIAL_FILE in actions

    private fun actionsFor(m: MobileMeeting): List<PhoneRecordingAction> {
        val directory = File(filesDir, MobileMeetingStore.RECORDINGS_DIRECTORY)
        val finalAudio = m.audioFileName == "${m.id}.m4a" && File(directory, "${m.id}.m4a").let { it.isFile && it.length() > 0 }
        val partialAudio = m.audioFileName == "${m.id}.m4a.partial" && File(directory, "${m.id}.m4a.partial").let { it.isFile && it.length() > 0 }
        return OrbitaBridgePolicy.recordingActions(m.status, finalAudio, partialAudio)
    }

    private var playingId: String? = null
    private fun play(id: String) {
        player?.release(); player = null; playingId = null
        background({ meetings.playbackUri(id) ?: error("El audio ya no está en este teléfono.") }) { uri ->
            player = MediaPlayer().apply {
                setDataSource(this@MainActivity, uri)
                setOnPreparedListener { it.start() }
                setOnCompletionListener { it.release(); if (player === it) { player = null; playingId = null } }
                prepareAsync()
            }
            playingId = id
        }
    }

    private fun setLocalTrashed(id: String, hidden: Boolean) {
        val meeting = meetings.find(id) ?: error("La reunión ya no está disponible.")
        check(if (hidden) meetings.trash(id) else meetings.restore(id)) { "No se pudo actualizar la reunión." }
        meeting.sourceEventKey?.let { key ->
            if (!store.hideOccurrence(key, hidden)) {
                if (hidden) meetings.restore(id) else meetings.trash(id)
                error("No se pudo actualizar el calendario local. Vuelve a intentarlo.")
            }
        }
    }

    private class TrashEntry(val label: String, val meeting: MobileMeeting?, val calendarId: String?, val actions: List<PhoneRecordingAction>)

    private fun showTrash() {
        val events = calendarEvents
        background({
            val all = meetings.list(includeTrashed = true)
            val linked = all.mapNotNull { it.sourceEventKey }.toSet()
            all.filter { it.trashedAtMs != null }.map { TrashEntry(it.title, it, null, actionsFor(it)) } +
                store.hiddenOccurrences().filterNot { it in linked }.map { occurrence ->
                    TrashEntry(events.find { it.occurrenceId == occurrence }?.title ?: "Evento del calendario", null, occurrence, emptyList())
                }
        }) { entries ->
            if (entries.isEmpty()) { message("La papelera está vacía."); return@background }
            AlertDialog.Builder(this).setTitle("Papelera").setItems(entries.map { it.label }.toTypedArray()) { _, index ->
                val entry = entries[index]
                val builder = AlertDialog.Builder(this).setTitle(entry.label)
                    .setMessage(if (entry.meeting != null) "Restaura la reunión o elimínala de este teléfono." else "El evento sigue en tu calendario; solo se ocultó en Hall-e.")
                    .setPositiveButton("Restaurar") { _, _ -> restoreEntry(entry) }
                    .setNegativeButton("Cerrar", null)
                if (entry.meeting != null && PhoneRecordingAction.DELETE in entry.actions)
                    builder.setNeutralButton("Eliminar…") { _, _ -> confirmDelete(DeleteCandidate(entry.meeting, entry.actions)) }
                builder.show()
            }.setNegativeButton("Cerrar", null).show()
        }
    }

    private fun restoreEntry(entry: TrashEntry) {
        background({
            entry.meeting?.let { setLocalTrashed(it.id, false) } ?: check(store.hideOccurrence(entry.calendarId!!, false))
        }) { refreshReminders(); publish(true); message("Reunión restaurada.") }
    }

    // --- Snapshot --------------------------------------------------------------------------------------------

    private fun publish(force: Boolean = false) {
        if (preview || !ready || !::web.isInitialized || isFinishing) return
        val events = calendarEvents; val preparing = pendingStartId != null; val linked = paired
        io.execute {
            val body = runCatching { snapshot(events, preparing, linked) }.getOrNull() ?: return@execute
            if (!force && body == lastSnapshot) return@execute
            lastSnapshot = body
            runOnUiThread { if (ready && !isFinishing) web.evaluateJavascript("window.hallEReceive && window.hallEReceive($body)", null) }
        }
    }

    /** Runs on [io]. */
    private fun snapshot(events: List<MeetingOccurrence>, preparing: Boolean, linked: Boolean): String {
        val all = meetings.list(); val active = all.firstOrNull { isRecordingInProgress(it.status) }; val array = JSONArray()
        all.forEach { array.put(meetingJSON(it)) }; val localOccurrences = all.mapNotNull { it.sourceEventKey }.toSet()
        events.filterNot { store.occurrenceHidden(it.occurrenceId) || it.occurrenceId in localOccurrences }.forEach { e ->
            array.put(JSONObject().put("id", "calendar:" + e.occurrenceId).put("calendar", true).put("title", e.title).put("project", store.projectFor(e.eventKey) ?: "")
                .put("date", Instant.ofEpochMilli(e.beginMillis).atZone(if (e.allDay) ZoneOffset.UTC else ZoneId.systemDefault()).toLocalDate().toString())
                .put("time", if (e.allDay) "Todo el día" else time(e.beginMillis)).put("startAtMs", e.beginMillis).put("status", "DRAFT")
                .put("hasMeetingUrl", e.meetingUrl != null).put("actions", JSONArray()))
        }
        return JSONObject().put("meetings", array).put("projects", JSONArray((store.projects() + all.mapNotNull { it.projectName }).distinct().sorted()))
            .put("active", active?.let(::meetingJSON) ?: JSONObject.NULL).put("preparing", preparing).put("paired", linked)
            .put("staging", BuildConfig.STAGING)
            .put("notificationsAllowed", NotificationManagerCompat.from(this).areNotificationsEnabled()).put("calendarPermission", calendar.hasPermission())
            .put("today", LocalDate.now().toString()).put("preview", preview).put("error", meetings.loadError ?: JSONObject.NULL)
            .put("reminderMinutes", store.alertMinutes).toString()
    }

    private fun meetingJSON(m: MobileMeeting): JSONObject {
        val actions = actionsFor(m)
        return JSONObject().put("id", m.id).put("title", m.title).put("project", m.projectName ?: "")
            .put("date", Instant.ofEpochMilli(m.scheduledStartAtMs ?: m.createdAtMs).atZone(ZoneId.systemDefault()).toLocalDate().toString())
            .put("time", time(m.scheduledStartAtMs ?: m.createdAtMs)).put("startAtMs", m.scheduledStartAtMs ?: m.createdAtMs)
            .put("status", m.status.name)
            .put("elapsedMs", if (m.status == MobileMeetingStatus.RECORDING && m.recordingStartedElapsedMs != null)
                (SystemClock.elapsedRealtime() - m.recordingStartedElapsedMs).coerceAtLeast(0) else m.durationMs)
            .put("hasAudio", PhoneRecordingAction.PLAY in actions)
            .put("actions", JSONArray(actions.map { it.name }))
            .put("shared", m.sharedSessionId != null)
            .put("trashedAtMs", m.trashedAtMs ?: JSONObject.NULL).put("error", m.error ?: JSONObject.NULL)
            .apply {
                if (PhoneRecordingAction.DELETE in actions) {
                    put("deleteTitle", personalDeleteTitleEs(m.status))
                    put("deleteMessage", personalDeleteMessageEs(m.title, hasAudio(actions), sharedSession = m.sharedSessionId != null))
                }
            }
    }

    private fun time(ms: Long) = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(ms))
    private fun result(value: JSONObject) { if (ready) web.evaluateJavascript("window.hallEResult && window.hallEResult($value)", null) }
    private fun showError(value: String) = result(JSONObject().put("error", value))
    private fun message(value: String) { result(JSONObject().put("message", value)); Toast.makeText(this, value, Toast.LENGTH_SHORT).show() }

    // --- Calendar, notes, reminders ----------------------------------------------------------------------------

    private fun refreshCalendar() {
        if (preview) return
        val date = rangeDate
        io.execute {
            val linked = runCatching { SharedSessionClient(this).paired() }.getOrDefault(false)
            val events = if (calendar.hasPermission()) runCatching {
                val zone = ZoneId.systemDefault()
                val start = date.withDayOfMonth(1).minusDays(7).atStartOfDay(zone).toInstant().toEpochMilli()
                val end = date.withDayOfMonth(1).plusMonths(1).plusDays(7).atStartOfDay(zone).toInstant().toEpochMilli()
                val selected = calendar.events(start, end)
                val today = LocalDate.now().atStartOfDay(zone).toInstant().toEpochMilli()
                if (today in start until end) selected
                else (selected + calendar.events(today, LocalDate.now().plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())).distinctBy { it.occurrenceId }
            }.getOrDefault(emptyList()) else emptyList()
            runOnUiThread { if (date == rangeDate && !isFinishing) { paired = linked; calendarEvents = events; publish(true) } }
        }
    }

    private fun eventFor(id: String): MeetingOccurrence? {
        val events = calendarEvents
        val source = if (id.startsWith("calendar:")) id.removePrefix("calendar:") else return null
        return events.firstOrNull { it.occurrenceId == source || it.eventKey == source }
    }

    private fun editNote(id: String) {
        val events = calendarEvents
        background({
            val source = if (id.startsWith("calendar:")) id.removePrefix("calendar:") else meetings.find(id)?.sourceEventKey
            val key = events.firstOrNull { it.occurrenceId == source || it.eventKey == source }?.eventKey ?: "mobile:$id"
            key to store.noteFor(key)
        }) { (key, note) ->
            val input = EditText(this).apply { setText(note); minLines = 5; textSize = 16f; setPadding(24, 16, 24, 16); gravity = android.view.Gravity.TOP }
            AlertDialog.Builder(this).setTitle("Nota local").setView(input)
                .setPositiveButton("Guardar") { _, _ -> val text = input.text.toString(); background({ store.saveNote(key, text) }) { message("Nota guardada en este teléfono.") } }
                .setNeutralButton("Compartir") { _, _ -> startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/markdown"; putExtra(Intent.EXTRA_TEXT, input.text.toString()) }, "Compartir nota")) }
                .setNegativeButton("Cancelar", null).show()
        }
    }

    private fun refreshReminders() { if (!preview) io.execute { runCatching { ReminderScheduler.refresh(this) } } }

    /** Shown once per morning (04:00–12:00) on opening, when calendar access is available and the overview is on. */
    private fun maybeShowMorningSummary() {
        if (preview || LocalTime.now().hour !in 4 until 12) return
        background({
            if (!store.morningSummaryEnabled || !calendar.hasPermission() || !store.morningSummaryFor(LocalDate.now())) return@background null
            val zone = ZoneId.systemDefault()
            val start = LocalDate.now().atStartOfDay(zone).toInstant().toEpochMilli()
            val end = LocalDate.now().plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
            ReminderPlanner.summaryEs(ReminderPlanner.forLocalDate(calendar.events(start, end), LocalDate.now()), System.currentTimeMillis())
        }) { summary -> summary?.let(::message) }
    }

    private fun chooseCalendars() {
        background({ calendar.calendars() to store.selectedCalendarIds.toMutableSet() }) { (values, selected) ->
            AlertDialog.Builder(this).setTitle("Calendarios").setMultiChoiceItems(values.map { it.name }.toTypedArray(), values.map { it.id in selected }.toBooleanArray()) { _, index, checked -> if (checked) selected.add(values[index].id) else selected.remove(values[index].id) }
                .setPositiveButton("Guardar") { _, _ -> background({ store.selectedCalendarIds = selected }) { refreshCalendar(); refreshReminders(); maybeRequestNotifications() } }
                .setNegativeButton("Cancelar", null).show()
        }
    }

    private fun maybeRequestNotifications(force: Boolean = false) {
        if (preview || !foreground) return
        val enabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
        if (Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            if (force && !enabled) startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            return
        }
        val prompts = PermissionPrompts(this)
        val asked = prompts.asked(Manifest.permission.POST_NOTIFICATIONS)
        if (!force && !shouldRequestNotificationPermission(Build.VERSION.SDK_INT, granted = false, askedBefore = asked)) return
        if (force && asked && !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)); return
        }
        prompts.markAsked(Manifest.permission.POST_NOTIFICATIONS)
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION)
    }

    private fun chooseReminders() {
        val values = intArrayOf(0, 1, 5, 10, 15, 30)
        background({ store.alertMinutes to store.morningSummaryEnabled }) { (minutes, morning) ->
            val labels = values.map { if (it == 0) "Al comenzar" else if (it == 1) "1 minuto antes" else "$it minutos antes" } + "Personalizado…"
            AlertDialog.Builder(this).setTitle("Avisar antes de la reunión").setSingleChoiceItems(labels.toTypedArray(), values.indexOf(minutes).takeIf { it >= 0 } ?: values.size) { dialog, index ->
                dialog.dismiss()
                if (index < values.size) background({ store.alertMinutes = values[index] }) { refreshReminders(); publish(true); maybeRequestNotifications() }
                else chooseCustomReminder(minutes)
            }.setNeutralButton(if (morning) "Desactivar resumen matinal" else "Activar resumen matinal") { _, _ ->
                background({ store.morningSummaryEnabled = !morning }) { refreshReminders() }
            }.setNegativeButton("Cancelar", null).show()
        }
    }

    private fun chooseCustomReminder(current: Int) {
        val input = EditText(this).apply { inputType = android.text.InputType.TYPE_CLASS_NUMBER; hint = "Minutos antes (1–1440)"; setText(current.toString()) }
        AlertDialog.Builder(this).setTitle("Aviso personalizado").setView(input)
            .setPositiveButton("Guardar") { _, _ ->
                val value = input.text.toString().toIntOrNull()
                if (value == null || value !in 1..1440) showError("Elige entre 1 y 1440 minutos.")
                else background({ store.alertMinutes = value }) { refreshReminders(); publish(true); maybeRequestNotifications() }
            }.setNegativeButton("Cancelar", null).show()
    }

    /** Confirms Android can show Hall-e's reminders, using the same channel as real meeting reminders. */
    private fun sendTestNotification() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            maybeRequestNotifications(force = true); return
        }
        val managerCompat = NotificationManagerCompat.from(this)
        if (!managerCompat.areNotificationsEnabled()) { showError("Las notificaciones de Hall-e están desactivadas en Ajustes de Android."); return }
        val manager = getSystemService(NotificationManager::class.java)
        manager?.createNotificationChannel(NotificationChannel(MeetingAlertReceiver.CHANNEL_ID, "Meeting reminders", NotificationManager.IMPORTANCE_HIGH)
            .apply { description = "Local reminders for selected calendar meetings" })
        if (manager?.getNotificationChannel(MeetingAlertReceiver.CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) {
            showError("Los recordatorios de reuniones están desactivados en Ajustes de Android."); return
        }
        runCatching {
            managerCompat.notify(TEST_NOTIFICATION_ID, NotificationCompat.Builder(this, MeetingAlertReceiver.CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle("Notificación de prueba de Hall-e")
                .setContentText("Si ves esto, Hall-e puede mostrar recordatorios.")
                .setAutoCancel(true).setPriority(NotificationCompat.PRIORITY_HIGH).build())
        }.onSuccess { message("Notificación de prueba enviada.") }
            .onFailure { showError("No se pudo enviar la notificación. Revisa los ajustes de notificaciones de Hall-e.") }
    }

    /** A meeting scheduled on a paired phone is offered to the shared workspace, as the native home screen did. */
    private fun shareDraftIfPaired(meeting: MobileMeeting) {
        if (BuildConfig.STAGING) return
        val client = SharedSessionClient(this)
        background({
            if (!client.paired()) null
            else runCatching { client.createSession(meeting) }.fold({ "Reunión guardada y compartida con tus dispositivos vinculados." },
                { "La reunión quedó guardada en este teléfono, pero no se pudo compartir." })
        }) { outcome -> outcome?.let(::message) }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_PERMISSION) {
            if (Manifest.permission.POST_NOTIFICATIONS in permissions) refreshReminders()
            val id = pendingStartId
            if (microphoneGranted() && id != null) startCapture(id)
            else {
                pendingStartId = null
                showError("No se concedió acceso al micrófono. La reunión quedó guardada sin grabar.")
                // An empty result means the request was cancelled, not denied.
                if (grantResults.isNotEmpty() && Manifest.permission.RECORD_AUDIO in permissions && microphoneNeedsSettings(micAskedBefore))
                    showMicrophoneSettingsDialog(MicrophoneSettingsCopy.SPANISH)
            }
        }
        if (requestCode == NOTIFICATION_PERMISSION) refreshReminders()
        if (requestCode == CALENDAR_PERMISSION && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) { refreshCalendar(); refreshReminders(); chooseCalendars() }
        publish(true)
    }

    override fun onDestroy() {
        ready = false; handler.removeCallbacksAndMessages(null)
        if (preparationHeld) releaseStartup(cancelled = true)
        io.shutdown(); player?.release(); player = null
        web.removeJavascriptInterface("HallENative"); web.destroy(); super.onDestroy()
    }

    companion object {
        const val EXTRA_PREVIEW = "HALLE_PREVIEW"
        const val EXTRA_START_RECORDING = "HALLE_START_RECORDING"
        private const val SHARED_SESSION_SCAN_REQUEST = 24
        private const val LEGACY_ORBITA_PROMPTS = "ui-permission-prompts"
        private const val ASSET_HOST = "appassets.androidplatform.net"
        private const val ASSET_URL = "https://appassets.androidplatform.net/index.html"
        private const val MIC_PERMISSION = 21
        private const val CALENDAR_PERMISSION = 22
        private const val NOTIFICATION_PERMISSION = 23
        private const val STARTUP_TIMEOUT_MS = 8_000L
        private const val TEST_NOTIFICATION_ID = 0x4841
        private const val BUSY = "Ya hay una grabación en curso o preparándose."
        private const val GENERIC_ERROR = "No se pudo completar la acción."
        private val BACKGROUND = Color.rgb(8, 14, 16)
    }
}
