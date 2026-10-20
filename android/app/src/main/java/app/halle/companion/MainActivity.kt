package app.halle.companion

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.MediaPlayer
import android.net.Uri
import android.provider.Settings
import android.widget.EditText
import android.widget.FrameLayout
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
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

/** Packaged Imba renderer. Microphone, calendar, files and credentials stay native. */
class MainActivity : Activity() {
    private lateinit var web: WebView
    private lateinit var store: LocalStore
    private lateinit var meetings: MobileMeetingStore
    private lateinit var calendar: CalendarRepository
    private val handler = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var foreground = false
    private var ready = false
    private var pendingStartId: String? = null
    private var pendingStartAt = 0L
    private var player: MediaPlayer? = null
    private var calendarEvents: List<MeetingOccurrence> = emptyList()
    private var rangeDate = LocalDate.now()
    private var lastSnapshot = ""
    private var preview = false
    private var paired = false
    private var reminderRegistered = false
    private var previousBrightness: Float? = null
    private val resetReminder = Runnable {
        previousBrightness?.let { old -> window.attributes = window.attributes.apply { screenBrightness = old } }
        previousBrightness = null
        if (ready) web.evaluateJavascript("document.documentElement.classList.remove('recording-reminder')", null)
    }
    private val reminderReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != RecordingScreenReminder.ACTION_REMINDER || !foreground || preview ||
                meetings.activeRecording()?.status != MobileMeetingStatus.RECORDING) return
            if (previousBrightness == null) previousBrightness = window.attributes.screenBrightness
            handler.removeCallbacks(resetReminder)
            window.attributes = window.attributes.apply { screenBrightness = 1f }
            if (ready) web.evaluateJavascript("window.hallEReminder?.()", null)
            handler.postDelayed(resetReminder, RecordingScreenReminder.PULSE_DURATION_MS)
        }
    }
    private val poll = object : Runnable {
        override fun run() {
            if (!foreground) return
            checkStartup(); publish()
            val active = meetings.activeRecording()
            if (active?.status == MobileMeetingStatus.RECORDING) maybeRequestNotifications()
            handler.postDelayed(this, if (active != null || pendingStartId != null) 250 else 1500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.rgb(8, 14, 16); window.navigationBarColor = Color.rgb(8, 14, 16)
        WindowCompat.getInsetsController(window, window.decorView).apply { isAppearanceLightStatusBars = false; isAppearanceLightNavigationBars = false }
        preview = BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_PREVIEW, false)
        store = LocalStore(this); meetings = MobileMeetingStore(this); if (!preview) meetings.recoverInterrupted(); calendar = CalendarRepository(this, store)
        if (BuildConfig.DEBUG) store.previewActive = preview
        web = WebView(this).apply { setBackgroundColor(Color.rgb(8, 14, 16)) }
        web.settings.apply {
            javaScriptEnabled = true; allowFileAccess = false; allowContentAccess = false; domStorageEnabled = false
            setSupportMultipleWindows(false); javaScriptCanOpenWindowsAutomatically = false
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW; mediaPlaybackRequiresUserGesture = true
        }
        web.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest): WebResourceResponse {
                val path = request.url.path.orEmpty()
                val mime = when (path) { "/index.html" -> "text/html"; "/app.js" -> "application/javascript"; "/app.css" -> "text/css"; "/hall-e.webp", "/hal.webp", "/wall-e.webp" -> "image/webp"; else -> null }
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
            setBackgroundColor(Color.rgb(8, 14, 16))
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
        ContextCompat.registerReceiver(this, reminderReceiver, IntentFilter(RecordingScreenReminder.ACTION_REMINDER), ContextCompat.RECEIVER_NOT_EXPORTED)
        reminderRegistered = true
        refreshCalendar(); refreshReminders()
        pendingStartId?.let { if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) startCapture(it) }
        PhoneAudioTransferWorker.kick(this); handler.removeCallbacks(poll); handler.post(poll)
    }
    override fun onPause() {
        foreground = false; handler.removeCallbacks(poll); handler.removeCallbacks(resetReminder); resetReminder.run()
        if (reminderRegistered) { unregisterReceiver(reminderReceiver); reminderRegistered = false }
        super.onPause()
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); consumeIntent(intent) }
    private fun consumeIntent(source: Intent) {
        if (preview) return
        source.getStringExtra(EXTRA_START_RECORDING)?.let { id ->
            source.removeExtra(EXTRA_START_RECORDING)
            // Existing shared handoffs retain their lease-controlled native journey.
            startActivity(Intent(this, LegacyActivity::class.java).putExtra(EXTRA_START_RECORDING, id))
        }
        source.getLongExtra(MeetingAlertReceiver.EXTRA_BEGIN, 0).takeIf { it > 0 }?.let { rangeDate = Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault()).toLocalDate(); refreshCalendar() }
    }
    inner class Bridge {
        @JavascriptInterface fun dispatch(action: String, raw: String) {
            if (raw.length > 4096 || action.length > 40) return
            val p = runCatching { JSONObject(raw) }.getOrNull() ?: return
            runOnUiThread { if (!isFinishing && ready && !preview) runCatching { handle(action, p) }.onFailure { showError(it.message ?: "No se pudo completar la acción.") } }
        }
    }
    private fun handle(action: String, p: JSONObject) {
        when (action) {
            "refresh" -> { publish(true); refreshCalendar() }
            "range" -> { rangeDate = LocalDate.parse(p.getString("date")); refreshCalendar() }
            "quickRecord" -> quickRecord()
            "recordMeeting" -> recordMeeting(p.getString("id"))
            "stop" -> { MeetingRecordingService.stop(this); handler.postDelayed({ publish(true); PhoneAudioTransferWorker.kick(this) }, 500) }
            "updateMeeting" -> {
                val id = p.getString("id"); val title = p.optString("title").trim()
                val previous = meetings.find(id) ?: error("La reunión ya no está disponible.")
                if (title.isNotBlank() && title != previous.title) check(meetings.updateTitle(id, title)) { "No se pudo guardar el nombre." }
                val project = p.optString("project").trim().takeIf(String::isNotBlank)
                if (project != previous.projectName) check(meetings.updateProject(id, project)) { "No se pudo guardar el proyecto." }; publish(true); message("Detalles guardados.")
            }
            "createProject" -> { check(store.addProject(p.getString("name")).isNotBlank()); publish(true) }
            "schedule" -> {
                val at = LocalDate.parse(p.getString("date")).atTime(LocalTime.parse(p.getString("time"))).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                meetings.createDraft(p.optString("title").ifBlank { "Nueva reunión" }, p.optString("project").takeIf(String::isNotBlank), null, at, at + 3_600_000); publish(true); refreshReminders(); maybeRequestNotifications()
            }
            "trash" -> {
                val id = p.getString("id"); val external = p.optBoolean("calendar")
                check(id != pendingStartId) { "Espera a que comience la grabación y luego detenla antes de eliminarla." }
                if (external) { check(store.hideOccurrence(id.removePrefix("calendar:"), true)); refreshReminders() } else setLocalTrashed(id, true)
                result(JSONObject().put("trash", JSONObject().put("id", id).put("calendar", external))); publish(true)
            }
            "restore" -> {
                val id = p.getString("id"); if (p.optBoolean("calendar")) { check(store.hideOccurrence(id.removePrefix("calendar:"), false)); refreshReminders() } else setLocalTrashed(id, false)
                publish(true); PhoneAudioTransferWorker.kick(this)
            }
            "play" -> play(p.getString("id"))
            "shareAudio" -> { val m = meetings.find(p.getString("id")) ?: error("La reunión ya no está disponible."); val share = meetings.shareIntent(m.id) ?: meetings.sharePartialFileIntent(m.id) ?: error("El audio ya no está en este teléfono."); startActivity(Intent.createChooser(share, "Compartir audio")) }
            "join" -> { val e = eventFor(p.getString("id")) ?: error("Actualiza el calendario y vuelve a intentarlo."); val link = e.meetingUrl ?: error("Esta reunión no tiene enlace."); startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link))) }
            "note" -> editNote(p.getString("id"))
            "pair" -> startActivity(Intent(this, SharedSessionActivity::class.java))
            "chooseMac" -> chooseMac()
            "calendarAccess" -> if (calendar.hasPermission()) chooseCalendars() else requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), CALENDAR_PERMISSION)
            "reminders" -> chooseReminders()
            "notifications" -> maybeRequestNotifications(force = true)
            "exactAlarms" -> startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
            "retryTransfers" -> { PhoneAudioTransferWorker.kick(this); message("Se reintentarán los envíos al Mac vinculado.") }
            "trashList" -> showTrash()
        }
    }
    private fun quickRecord() {
        if (preview || !foreground) return
        if (pendingStartId != null || meetings.activeRecording() != null || SharedSessionClient.recordingPreparationActive()) { showError("Ya hay una grabación en curso o preparándose."); publish(true); return }
        val m = meetings.createDraft("Reunión instantánea", null, null, System.currentTimeMillis(), null); requestCapture(m.id)
    }
    private fun recordMeeting(id: String) {
        if (preview || !foreground) return
        if (pendingStartId != null || meetings.activeRecording() != null || SharedSessionClient.recordingPreparationActive()) { showError("Ya hay una grabación en curso o preparándose."); publish(true); return }
        if (id.startsWith("calendar:")) {
            val event = calendarEvents.find { "calendar:" + it.occurrenceId == id } ?: error("Actualiza el calendario y vuelve a intentarlo.")
            requestCapture(meetings.createDraft(event.title, store.projectFor(event.eventKey), event.occurrenceId, event.beginMillis, event.endMillis).id)
        } else {
            val m = meetings.find(id) ?: error("La reunión ya no está disponible.")
            check(m.trashedAtMs == null) { "La reunión está en la papelera." }
            check(m.sharedSessionId == null) { "Abre Dispositivos vinculados para grabar una sesión compartida." }; requestCapture(id)
        }
    }
    private fun requestCapture(id: String) {
        pendingStartId = id; pendingStartAt = android.os.SystemClock.elapsedRealtime()
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_PERMISSION) else startCapture(id)
        publish(true)
    }
    private fun startCapture(id: String) {
        if (preview || !foreground || meetings.activeRecording() != null) return
        pendingStartAt = android.os.SystemClock.elapsedRealtime()
        if (!MeetingRecordingService.start(this, id)) { pendingStartId = null; showError("No se pudo iniciar el micrófono. La reunión está guardada.") }
    }
    private fun checkStartup() {
        val id = pendingStartId ?: return; val m = meetings.find(id)
        if (m?.status == MobileMeetingStatus.RECORDING) { pendingStartId = null; return }
        if (m?.status == MobileMeetingStatus.FAILED || android.os.SystemClock.elapsedRealtime() - pendingStartAt > 8_000 && checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            MeetingRecordingService.requestStop(this, id, "startup-timeout"); pendingStartId = null; showError("Android no confirmó el inicio del micrófono. La captura se detuvo de forma segura.")
        }
    }
    private fun refreshCalendar() {
        if (preview) return
        val date = rangeDate; val allowed = calendar.hasPermission() && !preview
        io.execute {
            val linked = SharedSessionClient(this).paired()
            val events = if (allowed) runCatching {
                val start = date.withDayOfMonth(1).minusDays(7).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
                val end = date.withDayOfMonth(1).plusMonths(1).plusDays(7).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
                val selected = calendar.events(start, end)
                val today = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
                if (today in start until end) selected else (selected + calendar.events(today, LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli())).distinctBy { it.occurrenceId }
            }.getOrDefault(emptyList()) else emptyList()
            runOnUiThread { if (date == rangeDate && !isFinishing) { paired = linked; calendarEvents = events; publish(true) } }
        }
    }
    private fun publish(force: Boolean = false) {
        if (preview || !ready || !::web.isInitialized || isFinishing) return
        val all = meetings.list(); val active = all.firstOrNull { it.status == MobileMeetingStatus.STARTING || it.status == MobileMeetingStatus.RECORDING }; val array = JSONArray()
        all.forEach { array.put(meetingJSON(it)) }; val localOccurrences = all.mapNotNull { it.sourceEventKey }.toSet()
        calendarEvents.filterNot { store.occurrenceHidden(it.occurrenceId) || it.occurrenceId in localOccurrences }.forEach { e ->
            array.put(JSONObject().put("id", "calendar:" + e.occurrenceId).put("calendar", true).put("title", e.title).put("project", store.projectFor(e.eventKey) ?: "")
                .put("date", Instant.ofEpochMilli(e.beginMillis).atZone(if (e.allDay) ZoneOffset.UTC else ZoneId.systemDefault()).toLocalDate().toString()).put("time", if (e.allDay) "Todo el día" else time(e.beginMillis)).put("startAtMs", e.beginMillis).put("status", "DRAFT").put("hasMeetingUrl", e.meetingUrl != null))
        }
        val body = JSONObject().put("meetings", array).put("projects", JSONArray((store.projects() + all.mapNotNull { it.projectName }).distinct().sorted()))
            .put("active", active?.let(::meetingJSON) ?: JSONObject.NULL).put("preparing", pendingStartId != null).put("paired", paired).put("notificationsAllowed", androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled()).put("calendarPermission", calendar.hasPermission())
            .put("today", LocalDate.now().toString()).put("preview", preview).put("error", meetings.loadError ?: JSONObject.NULL).put("reminderMinutes", store.alertMinutes).toString()
        if (force || body != lastSnapshot) { lastSnapshot = body; web.evaluateJavascript("window.hallEReceive && window.hallEReceive($body)", null) }
    }
    private fun meetingJSON(m: MobileMeeting): JSONObject = JSONObject().put("id", m.id).put("title", m.title).put("project", m.projectName ?: "")
        .put("date", Instant.ofEpochMilli(m.scheduledStartAtMs ?: m.createdAtMs).atZone(ZoneId.systemDefault()).toLocalDate().toString()).put("time", time(m.scheduledStartAtMs ?: m.createdAtMs)).put("startAtMs", m.scheduledStartAtMs ?: m.createdAtMs)
        .put("status", m.status.name).put("elapsedMs", if (m.status == MobileMeetingStatus.RECORDING && m.recordingStartedElapsedMs != null) (android.os.SystemClock.elapsedRealtime() - m.recordingStartedElapsedMs).coerceAtLeast(0) else m.durationMs)
        .put("hasAudio", m.audioFileName == "${m.id}.m4a" && File(File(filesDir, MobileMeetingStore.RECORDINGS_DIRECTORY), "${m.id}.m4a").isFile).put("transferState", m.transferState ?: JSONObject.NULL).put("error", m.error ?: JSONObject.NULL)
    private fun time(ms: Long) = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(ms))
    private fun result(value: JSONObject) { if (ready) web.evaluateJavascript("window.hallEResult && window.hallEResult($value)", null) }
    private fun showError(value: String) = result(JSONObject().put("error", value))
    private fun message(value: String) { result(JSONObject().put("message", value)); Toast.makeText(this, value, Toast.LENGTH_SHORT).show() }
    private fun play(id: String) {
        player?.release(); player = null; val uri = meetings.playbackUri(id) ?: error("El audio ya no está en este teléfono.")
        player = MediaPlayer().apply { setDataSource(this@MainActivity, uri); setOnCompletionListener { it.release(); player = null }; prepare(); start() }
    }
    private fun eventFor(id: String): MeetingOccurrence? {
        val source = if (id.startsWith("calendar:")) id.removePrefix("calendar:") else meetings.find(id)?.sourceEventKey
        return calendarEvents.firstOrNull { it.occurrenceId == source || it.eventKey == source }
    }
    private fun editNote(id: String) {
        val key = eventFor(id)?.eventKey ?: "mobile:$id"
        val input = EditText(this).apply { setText(store.noteFor(key)); minLines = 5; textSize = 16f; setPadding(24, 16, 24, 16); gravity = android.view.Gravity.TOP }
        AlertDialog.Builder(this).setTitle("Nota local").setView(input).setPositiveButton("Guardar") { _, _ -> store.saveNote(key, input.text.toString()); message("Nota guardada en este teléfono.") }
            .setNeutralButton("Compartir") { _, _ -> startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/markdown"; putExtra(Intent.EXTRA_TEXT, input.text.toString()) }, "Compartir nota")) }.setNegativeButton("Cancelar", null).show()
    }
    private fun refreshReminders() { io.execute { runCatching { ReminderScheduler.refresh(this) } } }
    private fun chooseMac() { io.execute {
        val choices = runCatching { PhoneAudioTransferWorker.recipientChoices(this) }
        runOnUiThread { choices.onSuccess { devices ->
            if (devices.isEmpty()) { showError("Abre Hall-e actualizado en tu Mac y vincula los dispositivos."); return@onSuccess }
            AlertDialog.Builder(this).setTitle("Mac para transcripciones").setItems(devices.map { it.second }.toTypedArray()) { _, index ->
                io.execute { val selected = runCatching { PhoneAudioTransferWorker.selectRecipient(this, devices[index].first) }; runOnUiThread { selected.onSuccess { message("Mac seleccionado.") }.onFailure { showError("No se pudo seleccionar ese Mac. Reintenta la conexión.") } } }
            }.setNegativeButton("Cancelar", null).show()
        }.onFailure { showError("No se pudo consultar el Mac. Tus grabaciones siguen guardadas.") } }
    } }
    private fun chooseCalendars() {
        val values = calendar.calendars(); val selected = store.selectedCalendarIds.toMutableSet()
        AlertDialog.Builder(this).setTitle("Calendarios").setMultiChoiceItems(values.map { it.name }.toTypedArray(), values.map { it.id in selected }.toBooleanArray()) { _, index, checked -> if (checked) selected.add(values[index].id) else selected.remove(values[index].id) }
            .setPositiveButton("Guardar") { _, _ -> store.selectedCalendarIds = selected; refreshCalendar(); refreshReminders(); maybeRequestNotifications() }.setNegativeButton("Cancelar", null).show()
    }
    private fun maybeRequestNotifications(force: Boolean = false) {
        if (preview || !foreground) return
        if (android.os.Build.VERSION.SDK_INT < 33) {
            if (force && !androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled())
                startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            if (force && !androidx.core.app.NotificationManagerCompat.from(this).areNotificationsEnabled())
                startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
            return
        }
        val prompts = getSharedPreferences("ui-permission-prompts", MODE_PRIVATE)
        if (!force && prompts.getBoolean("notificationsAsked", false)) return
        if (force && prompts.getBoolean("notificationsAsked", false) && !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)); return
        }
        prompts.edit().putBoolean("notificationsAsked", true).apply()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION)
    }
    private fun chooseReminders() {
        val values = intArrayOf(0, 1, 5, 10, 15, 30)
        AlertDialog.Builder(this).setTitle("Avisar antes de la reunión").setSingleChoiceItems(values.map { if (it == 0) "Al comenzar" else "$it minutos antes" }.toTypedArray(), values.indexOf(store.alertMinutes)) { dialog, index ->
            store.alertMinutes = values[index]; refreshReminders(); dialog.dismiss()
            if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION)
        }.setNeutralButton(if (store.morningSummaryEnabled) "Desactivar resumen matinal" else "Activar resumen matinal") { _, _ -> store.morningSummaryEnabled = !store.morningSummaryEnabled; refreshReminders() }.setNegativeButton("Cancelar", null).show()
    }
    private fun setLocalTrashed(id: String, hidden: Boolean) {
        val meeting = meetings.find(id) ?: error("La reunión ya no está disponible.")
        check(if (hidden) meetings.trash(id) else meetings.restore(id))
        meeting.sourceEventKey?.let { key ->
            if (!store.hideOccurrence(key, hidden)) {
                if (hidden) meetings.restore(id) else meetings.trash(id)
                error("No se pudo actualizar el calendario local. Vuelve a intentarlo.")
            }
        }
        refreshReminders()
    }
    private fun showTrash() {
        val all = meetings.list(includeTrashed = true)
        val linked = all.mapNotNull { it.sourceEventKey }.toSet()
        val trashed = all.filter { it.trashedAtMs != null }; val events = store.hiddenOccurrences().filterNot { it in linked }.map { "calendar:$it" }
        val labels = trashed.map { it.title } + events.map { id -> calendarEvents.find { "calendar:" + it.occurrenceId == id }?.title ?: "Evento del calendario" }
        if (labels.isEmpty()) { message("La papelera está vacía."); return }
        AlertDialog.Builder(this).setTitle("Restaurar reunión").setItems(labels.toTypedArray()) { _, index ->
            if (index < trashed.size) setLocalTrashed(trashed[index].id, false) else { val id = events[index - trashed.size]; store.hideOccurrence(id.removePrefix("calendar:"), false); refreshReminders() }
            publish(true); PhoneAudioTransferWorker.kick(this)
        }.setNegativeButton("Cerrar", null).show()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == MIC_PERMISSION) {
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) pendingStartId?.let { startCapture(it) }
            else { pendingStartId = null; showError("No se concedió acceso al micrófono. Puedes volver a intentarlo.") }
        }
        if (requestCode == NOTIFICATION_PERMISSION) refreshReminders()
        if (requestCode == CALENDAR_PERMISSION && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) { refreshCalendar(); chooseCalendars() }; publish(true)
    }
    override fun onDestroy() { ready = false; handler.removeCallbacksAndMessages(null); io.shutdown(); player?.release(); web.removeJavascriptInterface("HallENative"); web.destroy(); super.onDestroy() }
    companion object {
        const val EXTRA_PREVIEW = "HALLE_PREVIEW"
        const val EXTRA_START_RECORDING = "HALLE_START_RECORDING"
        const val TRANSFER_PREFS = "orbita-new-captures"
        private const val ASSET_HOST = "appassets.androidplatform.net"
        private const val ASSET_URL = "https://appassets.androidplatform.net/index.html"
        private const val MIC_PERMISSION = 21
        private const val CALENDAR_PERMISSION = 22
        private const val NOTIFICATION_PERMISSION = 23
    }
}
