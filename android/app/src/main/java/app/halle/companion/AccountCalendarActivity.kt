package app.halle.companion

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.UUID
import java.util.concurrent.Executors

class AccountCalendarActivity : Activity() {
    private lateinit var sessions: AccountSessions
    private lateinit var page: LinearLayout
    private lateinit var bar: LinearLayout
    private lateinit var scroll: ScrollView
    private val ui by lazy { OrbitaKit(this) }
    private var screen = ""
    private val auth = Executors.newSingleThreadExecutor()
    private val timer = Handler(Looper.getMainLooper())
    private var selected: String? = null
    private var day: LocalDate? = null
    private var status = ""
    private var syncing = false
    private var signing = false
    private var deleting = false
    private var active = false
    private val transcriptLoads = mutableMapOf<String, TranscriptLoad>()
    private var player: android.media.MediaPlayer? = null
    private var consent: (() -> Unit)? = null
    private var micAskedBefore = false
    private val projectDialogs = mutableMapOf<AlertDialog, String>()
    private fun AlertDialog.Builder.showFor(cal: AccountCalendar) {
        if (sessions.current()?.token != cal.session.token) return
        val dialog = create()
        projectDialogs[dialog] = cal.session.token
        dialog.setOnDismissListener { projectDialogs.remove(dialog) }
        dialog.show()
    }
    private val tick = object : Runnable {
        override fun run() {
            if (!active) return
            if (sessions.current() != null && sessions.browserPending() == null) sync()
            timer.postDelayed(this, 12000)
        }
    }

    override fun onCreate(state: Bundle?) {
        // The manifest theme is shared with other screens; this one is always Orbita's dark surface.
        setTheme(android.R.style.Theme_Material_NoActionBar)
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        sessions = AccountSessions(this)
        selected = state?.getString("meeting")
        val dayString = if (state == null) intent.getStringExtra(EXTRA_DAY) else state.getString("day")
        day = dayString?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        AccountSyncJob.periodic(this, sessions.current() != null)
        buildFrame()
    }
    override fun onResume() { super.onResume(); active = true; render(); timer.post(tick) }
    override fun onPause() { player?.release(); player = null; active = false; timer.removeCallbacks(tick); super.onPause() }
    override fun onDestroy() { auth.shutdownNow(); super.onDestroy() }
    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putString("meeting", selected); out.putString("day", day?.toString()) }

    /** Fixed top bar over a scrolling page; the root takes the system-bar and cutout insets (edge-to-edge). */
    private fun buildFrame() {
        bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(12), ui.dp(6), ui.dp(16), ui.dp(4))
            setBackgroundColor(OrbitaColors.BG)
        }
        page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(ui.dp(24), ui.dp(4), ui.dp(24), ui.dp(40)) }
        scroll = ScrollView(this).apply {
            isFillViewport = true; overScrollMode = View.OVER_SCROLL_IF_CONTENT_SCROLLS
            addView(page)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(OrbitaColors.BG)
            addView(bar); addView(scroll)
            setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars() or
                    android.view.WindowInsets.Type.displayCutout())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom); insets
            }
        }
        setContentView(root)
        applyOrbitaWindow()
    }

    /** Top bar: back to Orbita (or to the agenda from a meeting) and the mint chest lens. */
    private fun topBar(inMeeting: Boolean) {
        bar.removeAllViews()
        bar.addView(if (inMeeting) ui.button(OrbitaButton.TEXT, "← Agenda", "Volver a la agenda") { selected = null; render() }
            else ui.button(OrbitaButton.TEXT, "← Orbita", "Volver a Orbita") { finish() })
        bar.addView(View(this).apply { layoutParams = LinearLayout.LayoutParams(0, 1, 1f) })
        bar.addView(ui.chestLens())
    }

    /** Keeps the scroll position while the same screen re-renders (sync runs every few seconds). */
    private fun settle(key: String, previousScroll: Int) {
        val keep = key == screen
        screen = key
        scroll.post { scroll.scrollTo(0, if (keep) previousScroll else 0) }
    }

    private fun add(view: View, into: LinearLayout = page) { into.addView(view) }
    private fun action(kind: OrbitaButton, label: String, into: LinearLayout = page, description: String? = null, block: () -> Unit) {
        into.addView(ui.button(kind, label, description) { safely(block) })
    }
    private fun safely(block: () -> Unit) {
        try { block() } catch (_: IllegalArgumentException) { message("Revisa la dirección del servidor, el título y las fechas.") }
        catch (_: IllegalStateException) { message("No se pudo guardar este cambio. Revisa el espacio disponible y los cambios pendientes.") }
    }
    private fun message(value: String) { Toast.makeText(this, value, Toast.LENGTH_LONG).show() }
    private fun input(hintText: String, value: String = "") = ui.input(hintText, value)
    private fun dialog(danger: Boolean = false): AlertDialog.Builder = OrbitaDialogBuilder(this, ui, danger)

    private fun usesStagingMailbox(origin: String): Boolean = BuildConfig.STAGING && BuildConfig.ACCOUNT_ORIGIN.isNotEmpty() &&
        runCatching { accountOrigin(origin) }.getOrNull() == BuildConfig.ACCOUNT_ORIGIN

    private fun render() {
        if (isFinishing || isDestroyed) return
        val session = sessions.current()
        projectDialogs.filterValues { it != session?.token }.keys.toList().forEach { it.dismiss() }
        val previousScroll = scroll.scrollY
        page.removeAllViews()
        if (session == null) {
            selected = null
            topBar(false)
            add(ui.eyebrow("Agenda privada"))
            add(ui.title("Entra a tu cuenta"))
            if (status.isNotBlank()) add(ui.message(status))
            add(ui.muted("Usa el mismo servidor de cuenta que tu computador. Las reuniones que crees aquí son privadas para tu cuenta.", 15f))
            googlePending()
            action(OrbitaButton.PRIMARY, "Entrar con correo") { beginAuth(false, null) }
            if (usesStagingMailbox(sessions.lastOrigin)) {
                add(ui.muted("Pide un código por dispositivo. Ábrelo en el Mac con Hall-e Staging Code.command.", 13f)
                    .apply { layoutParams = ui.params(top = 12) })
            } else action(OrbitaButton.SECONDARY, "Entrar con Google") { beginAuth(true, null) }
            if (BuildConfig.STAGING) {
                action(OrbitaButton.TEXT, "Cambiar servidor de cuenta…") {
                    val server = input("Servidor de cuenta HTTPS", sessions.lastOrigin)
                    dialog().setTitle("Servidor de cuenta").setView(ui.fields(ui.field("Dirección HTTPS", server)))
                        .setNegativeButton("Cancelar", null).setPositiveButton("Guardar") { _, _ -> safely {
                            sessions.lastOrigin = accountOrigin(server.text.toString()); render()
                        } }.show()
                }
            }
            settle("signin", previousScroll)
            return
        }
        val cal = AccountCalendar(this, session)
        cal.media.recoverInterrupted()
        val rows = cal.visible()
        val meeting = rows.firstOrNull { it.getString("id") == selected }
        if (meeting != null) {
            topBar(true)
            if (status.isNotBlank()) add(ui.message(status).apply { layoutParams = ui.params(top = 8) })
            googlePending()
            showMeeting(cal, meeting)
            settle("meeting:" + meeting.getString("id"), previousScroll)
            return
        }
        selected = null
        topBar(false)
        add(ui.eyebrow("Agenda privada"))
        add(ui.title("Tu agenda"))
        add(ui.text(session.origin, 12f, OrbitaColors.MUTED, ui.mono, 18f))
        if (status.isNotBlank()) add(ui.message(status).apply { layoutParams = ui.params(top = 12) })
        googlePending()
        action(OrbitaButton.PRIMARY, "+ Nueva reunión") { edit(cal, null) }
        action(OrbitaButton.SECONDARY, "Sincronizar ahora") { sync() }
        val problems = cal.mutationIds().mapNotNull { id -> cal.pending(id)?.takeIf { it.has("problem") }?.let { id to it } }
        if (problems.isNotEmpty()) {
            add(ui.heading("Cambios por revisar"))
            for ((id, pending) in problems) {
                val card = ui.card()
                add(ui.text(pending.getString("title").ifBlank { "Reunión sin título" }, 16f, face = ui.medium, lineSp = 22f), card)
                add(ui.muted("Este cambio necesita tu atención."), card)
                action(OrbitaButton.SECONDARY, "Resolver cambio", card, "Resolver cambio de " + pending.getString("title")) { resolve(cal, id) }
                add(card)
            }
        }
        val chosenDay = day
        val today = LocalDate.now()
        val displayed = if (chosenDay == null) rows else {
            val zone = ZoneId.systemDefault()
            val begin = chosenDay.atStartOfDay(zone).toInstant()
            val end = chosenDay.plusDays(1).atStartOfDay(zone).toInstant()
            rows.filter { Instant.parse(it.getString("startAt")) < end && Instant.parse(it.getString("endAt")) > begin }
        }
        add(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            layoutParams = ui.params(top = 24)
            addView(ui.heading(chosenDay?.let { AgendaCopy.dayLabel(it, today) } ?: "Todas las fechas").apply {
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            })
            addView(ui.button(OrbitaButton.TEXT, if (chosenDay == null) "Elegir fecha" else "Cambiar fecha") { safely {
                val date = day ?: LocalDate.now()
                android.app.DatePickerDialog(this@AccountCalendarActivity, { _, y, month, d -> day = LocalDate.of(y, month+1, d); render() },
                    date.year, date.monthValue-1, date.dayOfMonth).apply { setOnShowListener { ui.styleDialog(this) } }.show()
            } }.apply { layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT) })
        })
        if (chosenDay != null) action(OrbitaButton.TEXT, "Ver todas las fechas") { day = null; render() }
        add(View(this).apply {
            setBackgroundColor(OrbitaColors.LINE)
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, maxOf(1, ui.dp(1))).apply { topMargin = ui.dp(8) }
        })
        val zone = ZoneId.systemDefault()
        for (row in displayed) {
            val start = Instant.parse(row.getString("startAt")).atZone(zone)
            val title = row.optString("title").ifBlank { "Reunión eliminada" }
            val project = AccountProject.read(row.optJSONObject("project"))?.name ?: "Sin proyecto"
            add(ui.row(AgendaCopy.rowDate(start), AgendaCopy.rowTime(start), title, project, null,
                "$title, ${AgendaCopy.dayLabel(start.toLocalDate(), today)}, ${AgendaCopy.rowTime(start)}, $project") { safely {
                selected = row.getString("id"); render()
            } })
        }
        if (displayed.isEmpty()) add(ui.muted("No hay reuniones en estas fechas. Tu agenda tiene espacio.", 13f)
            .apply { setPadding(0, ui.dp(18), 0, ui.dp(18)) })
        val orphans = cal.orphanedRecordings()
        if (orphans.isNotEmpty()) {
            add(ui.heading("Grabaciones de reuniones eliminadas"))
            add(ui.muted("Estas copias siguen en tu teléfono."))
            for (orphan in orphans) {
                val card = ui.card()
                add(ui.text(orphan.title, 16f, face = ui.medium, lineSp = 22f), card)
                add(ui.muted(AgendaCopy.phoneStatus(orphan.status)), card)
                cal.media.completedAudio(orphan.id)?.let { file ->
                    action(OrbitaButton.SECONDARY, "Escuchar copia del teléfono", card, "Escuchar copia del teléfono de " + orphan.title) {
                        playLocalFile(cal, file)
                    }
                }
                action(OrbitaButton.DANGER_QUIET, "Eliminar copia del teléfono…", card, "Eliminar copia del teléfono de " + orphan.title) {
                    dialog(danger = true).setTitle("¿Eliminar la copia del teléfono?")
                        .setMessage("Esta reunión se eliminó de tu cuenta. Al eliminarla se borra el archivo de audio de este teléfono.")
                        .setNegativeButton("Cancelar", null)
                        .setPositiveButton("Eliminar") { _, _ -> cal.deleteOrphanedRecording(orphan.id); render() }
                        .showFor(cal)
                }
                add(card)
            }
        }
        add(ui.heading("Cuenta"))
        action(OrbitaButton.SECONDARY, "Copiar una reunión local…") { importMeeting(cal) }
        if (!usesStagingMailbox(session.origin)) action(OrbitaButton.SECONDARY, "Vincular otro método de inicio…") {
            dialog().setTitle("Vincular a esta cuenta de Hall-e")
                .setItems(arrayOf("Código por correo", "Google")) { _, i -> beginAuth(i == 1, session) }.show()
        }
        action(OrbitaButton.SECONDARY, "Cerrar sesión") {
            player?.release(); player = null
            cal.media.activeRecording()?.let { MeetingRecordingService.requestStop(this, it.id, "user") }
            sessions.logout(session, true)
            AccountSyncJob.periodic(this, false)
            AccountSyncJob.schedule(this)
            selected = null; status = "Sesión cerrada. Los cambios pendientes se quedan en este teléfono para la misma cuenta."
            render()
        }
        if (cal.features().accountDeletion) action(OrbitaButton.DANGER_QUIET, "Eliminar cuenta…") { confirmAccountDeletion(cal) }
        settle("list", previousScroll)
    }

    /** A Google sign-in waiting for its browser confirmation code. */
    private fun googlePending() {
        if (sessions.browserPending() == null) return
        val card = ui.card()
        add(ui.text("Falta confirmar Google", 16f, face = ui.medium, lineSp = 22f), card)
        add(ui.muted("Ingresa el código que muestra el navegador para terminar."), card)
        action(OrbitaButton.PRIMARY, "Ingresar código de Google", card) { finishGoogle() }
        action(OrbitaButton.TEXT, "Cancelar inicio con Google", card) { sessions.browserPending(null); render() }
        add(card)
    }

    private fun local(raw: String): String = Instant.parse(raw).atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))
    private fun showMeeting(cal: AccountCalendar, m: JSONObject) {
        val id = m.getString("id")
        val zone = ZoneId.systemDefault()
        val start = Instant.parse(m.getString("startAt")).atZone(zone)
        val end = Instant.parse(m.getString("endAt")).atZone(zone)
        add(ui.eyebrow(AgendaCopy.dayLabel(start.toLocalDate(), LocalDate.now())))
        add(ui.title(m.optString("title").ifBlank { "Reunión eliminada" }, 30f))
        add(ui.muted(AccountProject.read(m.optJSONObject("project"))?.name ?: "Sin proyecto", 15f))
        add(ui.text(AgendaCopy.timeRange(start, end), 13f, OrbitaColors.MUTED, ui.mono, 20f))
        val pending = cal.pending(id)
        if (pending != null) {
            val card = ui.card()
            add(ui.text(if (pending.has("problem")) "Este cambio necesita tu atención." else "Cambio en cola en este teléfono.",
                14f, lineSp = 21f).apply { accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }, card)
            if (pending.has("problem")) action(OrbitaButton.SECONDARY, "Revisar conflicto", card) { resolve(cal, id) }
            add(card)
        }
        if (!m.optBoolean("deleted")) action(OrbitaButton.PRIMARY, "Grabar esta reunión…") { chooseRecording(cal, m) }
        if (pending == null) action(OrbitaButton.SECONDARY, "Editar reunión") { edit(cal, m) }
        val remote = (m.optJSONArray("recordings") ?: JSONArray()).objects()
        if (!m.optBoolean("deleted") && usesStagingMailbox(cal.session.origin)) {
            action(OrbitaButton.SECONDARY, "Enviar tono de prueba") {
                if (sessions.current()?.token == cal.session.token) {
                    try {
                        val bytes = assets.open("phone-tone.mp4").use { it.readBytes() }
                        val sampleId = cal.media.installStagingTone(id, bytes)
                        if (remote.none { it.optString("id") == sampleId } && cal.upload(sampleId) == null) {
                            cal.enqueueAudio(id, sampleId, "deepgram")
                        }
                        changed()
                    } catch (_: java.io.IOException) {
                        message("No se pudo guardar el tono de prueba.")
                    }
                }
            }
        }
        if (pending == null) action(OrbitaButton.DANGER_QUIET, "Eliminar de la cuenta…") {
            dialog(danger = true).setTitle("¿Eliminar esta reunión?")
                .setMessage("Se elimina de tu cuenta junto con sus grabaciones compartidas, en todos tus dispositivos.")
                .setNegativeButton("Cancelar", null).setPositiveButton("Eliminar") { _, _ ->
                    safely { cal.stage(id, m.getString("title"), Instant.parse(m.getString("startAt")),
                        Instant.parse(m.getString("endAt")), m.getInt("revision"), true); changed() }
                }.show()
        }
        val drafts = cal.recordings(id)
        if (remote.isNotEmpty() || drafts.isNotEmpty()) add(ui.heading("Grabaciones"))
        for (r in remote) {
            val card = ui.card()
            add(ui.eyebrow("En tu cuenta").apply { layoutParams = ui.params(bottom = 4) }, card)
            val raw = r.getString("status")
            add(ui.status(AgendaCopy.recordingStatus(raw) + (r.optNullableString("detail")?.let { " · $it" } ?: ""),
                if (isDiscardableRecording(r)) OrbitaColors.DANGER_TEXT else OrbitaColors.MINT), card)
            val inline = inlineTranscript(r)
            if (inline != null) add(transcript(inline), card) else if (hasRemoteTranscript(r)) showRemoteTranscript(cal, id, r, card)
            if (isDiscardableRecording(r)) action(OrbitaButton.DANGER_QUIET, "Descartar grabación…", card) {
                dialog(danger = true).setTitle("¿Descartar esta grabación de tu cuenta?")
                    .setMessage("El servicio se detuvo en esta grabación. Al descartarla se borran su audio y cualquier borrador " +
                        "de transcripción de tu cuenta, en todos tus dispositivos. La copia guardada en este teléfono no se elimina.")
                    .setNegativeButton("Cancelar", null)
                    .setPositiveButton("Descartar") { _, _ -> discardRecording(cal, id, r.getString("id")) }
                    .showFor(cal)
            }
            add(card)
        }
        for (draft in drafts) {
            val card = ui.card()
            val queue = cal.upload(draft.id)
            val shared = remote.any { it.getString("id") == draft.id }
            add(ui.eyebrow("En este teléfono").apply { layoutParams = ui.params(bottom = 4) }, card)
            add(ui.status(AgendaCopy.phoneRecordingLine(draft.status, queue, usesStagingMailbox(cal.session.origin), shared), when {
                isRecordingInProgress(draft.status) -> OrbitaColors.RECORDING
                queue?.has("problem") == true -> OrbitaColors.DANGER_TEXT
                else -> OrbitaColors.MINT
            }), card)
            draft.error?.let { add(ui.body(it, 14f), card) }
            val audio = cal.media.completedAudio(draft.id)
            val offered = accountRecordingActions(draft.status, playable = audio != null, queued = queue != null,
                uploadProblem = queue?.has("problem") == true, uploaded = shared)
            if (draft.status == MobileMeetingStatus.INTERRUPTED && audio == null) {
                add(ui.muted("No se guardó un archivo de audio terminado, así que esta grabación no se puede reproducir ni subir."), card)
            }
            for (offer in offered) when (offer) {
                PhoneRecordingAction.PLAY -> audio?.let { file ->
                    action(OrbitaButton.SECONDARY, "Escuchar copia del teléfono", card) { playLocalFile(cal, file) }
                }
                PhoneRecordingAction.RETRY_UPLOAD -> action(OrbitaButton.SECONDARY, "Reintentar subida", card) {
                    cal.retryUpload(draft.id); changed()
                }
                PhoneRecordingAction.CANCEL_UPLOAD -> action(OrbitaButton.TEXT, "Cancelar subida", card) {
                    cal.discardUpload(draft.id); changed()
                }
                PhoneRecordingAction.STOP -> action(OrbitaButton.DANGER, "Detener grabación", card) {
                    MeetingRecordingService.requestStop(this, draft.id, "user"); timer.postDelayed({ render() }, 650)
                }
                PhoneRecordingAction.SEND -> if (usesStagingMailbox(cal.session.origin)) {
                    add(ui.muted("Esta grabación se queda en tu teléfono. Usa «Enviar tono de prueba» para probar la sincronización de staging.", 13f), card)
                } else action(OrbitaButton.PRIMARY, "Enviar a transcribir…", card) {
                    provider(cal, false) { p -> cal.enqueueAudio(id, draft.id, p!!); changed() }
                }
                PhoneRecordingAction.DELETE -> action(OrbitaButton.DANGER_QUIET, "Eliminar copia del teléfono…", card) {
                    dialog(danger = true).setTitle("¿Eliminar la copia del teléfono?")
                        .setMessage(AgendaCopy.deletePhoneCopyMessage(queued = queue != null, uploaded = shared))
                        .setNegativeButton("Cancelar", null)
                        .setPositiveButton("Eliminar") { _, _ -> safely {
                            if (sessions.current()?.token != cal.session.token) return@safely
                            player?.release(); player = null
                            if (!cal.deleteLocalRecording(draft.id)) message("No se pudo eliminar la copia del teléfono. Revisa el espacio disponible.")
                            changed()
                        } }
                        .showFor(cal)
                }
                PhoneRecordingAction.SHARE_AUDIO, PhoneRecordingAction.SHARE_PARTIAL_FILE -> Unit
            }
            add(card)
        }
    }

    private fun transcript(text: String) = ui.text(text, 15f, lineSp = 23f).apply { layoutParams = ui.params(top = 10, bottom = 4) }

    private fun showRemoteTranscript(cal: AccountCalendar, meetingId: String, recording: JSONObject, into: LinearLayout) {
        val recordingId = recording.getString("id")
        val key = cal.session.scope + "/" + recordingId.lowercase(java.util.Locale.ROOT)
        val state = transcriptLoads[key]
        if (state is TranscriptLoad.Loaded) { add(transcript(state.text), into); return }
        cal.cachedTranscript(recording)?.let { add(transcript(it), into); return }
        when (state) {
            null, TranscriptLoad.Loading -> {
                if (state == null) loadTranscript(cal, meetingId, recordingId, key)
                add(ui.muted("Cargando transcripción…").apply { accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }, into)
            }
            TranscriptLoad.Missing -> add(ui.muted("Esta grabación no tiene transcripción guardada."), into)
            is TranscriptLoad.Failed -> {
                add(ui.status(state.reason, OrbitaColors.DANGER_TEXT), into)
                action(OrbitaButton.TEXT, "Reintentar transcripción", into) { transcriptLoads.remove(key); render() }
            }
            is TranscriptLoad.Loaded -> Unit
        }
    }

    private fun loadTranscript(cal: AccountCalendar, meetingId: String, recordingId: String, key: String) {
        val session = cal.session
        transcriptLoads[key] = TranscriptLoad.Loading
        auth.execute {
            val result = runCatching {
                cal.loadTranscript(meetingId, recordingId) { path ->
                    if (sessions.current()?.token != session.token) throw java.io.IOException("Session changed")
                    AccountTransport.requestText(session.origin, path, session.token)
                }
            }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                result.onSuccess { text ->
                    transcriptLoads[key] = text?.let(TranscriptLoad::Loaded) ?: TranscriptLoad.Missing
                }.onFailure { error ->
                    if (error is AccountHttpError && error.status == 401) sessions.logout(session, false)
                    transcriptLoads[key] = TranscriptLoad.Failed(if (error is AccountHttpError)
                        "No se pudo cargar la transcripción (HTTP ${error.status})." else "No se pudo cargar la transcripción. Revisa la conexión.")
                }
                render()
            }
        }
    }

    private fun confirmAccountDeletion(cal: AccountCalendar) {
        val typed = input("Escribe $ACCOUNT_DELETION_CONFIRMATION").apply {
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
        }
        if (sessions.current()?.token != cal.session.token) return
        val dialog = dialog(danger = true).setTitle("¿Eliminar esta cuenta de Hall-e?")
            .setMessage("Se borran para siempre las reuniones, transcripciones y audios de la cuenta en el servicio, " +
                "y se cierra la sesión en todos tus dispositivos. No se puede deshacer. Las grabaciones de este teléfono " +
                "pasan a tu biblioteca personal.\n\nEscribe $ACCOUNT_DELETION_CONFIRMATION para confirmar.")
            .setView(ui.fields(ui.field("Confirmación", typed))).setNegativeButton("Cancelar", null)
            .setPositiveButton("Eliminar cuenta") { _, _ ->
                if (isAccountDeletionConfirmed(typed.text.toString())) deleteAccount(cal)
                else message("Escribe $ACCOUNT_DELETION_CONFIRMATION para eliminar la cuenta.")
            }.create()
        projectDialogs[dialog] = cal.session.token
        dialog.setOnDismissListener { projectDialogs.remove(dialog) }
        dialog.setOnShowListener {
            ui.styleDialog(dialog, danger = true)
            val confirm = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
            confirm.isEnabled = false
            typed.addTextChangedListener(object : android.text.TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: android.text.Editable?) {
                    confirm.isEnabled = isAccountDeletionConfirmed(s?.toString().orEmpty())
                }
            })
        }
        dialog.show()
    }

    private fun deleteAccount(cal: AccountCalendar) {
        val session = cal.session
        if (deleting || sessions.current()?.token != session.token) return
        deleting = true
        status = "Eliminando cuenta…"
        render()
        AccountSync.deleteAccount(applicationContext, session) { error -> runOnUiThread {
            deleting = false
            val deleted = error == null || error is LocalWipeIncomplete
            if (deleted) {
                player?.release(); player = null
                cal.media.activeRecording()?.let { MeetingRecordingService.requestStop(this, it.id, "user") }
                AccountSyncJob.periodic(this, false)
                transcriptLoads.keys.removeAll { it.startsWith(session.scope + "/") }
                selected = null
            }
            status = when {
                error == null -> "Cuenta eliminada. Las grabaciones de este teléfono pasan a tu biblioteca personal."
                error is LocalWipeIncomplete -> "Cuenta eliminada. Algunos datos guardados en este teléfono no se pudieron borrar."
                error is AccountHttpError && error.reason == "deletion_disabled" ->
                    "Este servidor no permite eliminar cuentas. No se cambió nada."
                error is AccountHttpError && error.status == 401 -> "La sesión expiró. Vuelve a entrar para continuar."
                error is AccountHttpError -> "No se pudo eliminar la cuenta (HTTP ${error.status}). No se cambió nada."
                else -> "No se pudo eliminar la cuenta. Revisa la conexión; no se cambió nada."
            }
            message(status)
            if (!isFinishing && !isDestroyed) render()
        } }
    }

    private fun playLocalFile(cal: AccountCalendar, file: java.io.File) {
        if (sessions.current()?.token != cal.session.token) return
        player?.release()
        val audio = android.media.MediaPlayer()
        player = audio
        runCatching {
            audio.setDataSource(file.absolutePath)
            audio.setOnPreparedListener { if (active && player === it) it.start() }
            audio.setOnCompletionListener { it.release(); if (player === it) player = null }
            audio.setOnErrorListener { failed, _, _ ->
                failed.release(); if (player === failed) player = null
                message("No se pudo reproducir la copia del teléfono."); true
            }
            audio.prepareAsync()
        }.onFailure { audio.release(); player = null; message("No se pudo reproducir la copia del teléfono.") }
    }

    private fun discardRecording(cal: AccountCalendar, meetingId: String, recordingId: String) {
        val session = cal.session
        auth.execute {
            val result = runCatching {
                cal.discardRemoteRecording(meetingId, recordingId) { path, method, body, bytes ->
                    if (sessions.current()?.token != session.token) throw java.io.IOException("Session changed")
                    AccountTransport.request(session.origin, path, method, session.token, body, bytes)
                }
            }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                result.onSuccess { discarded ->
                    message(if (discarded) "Grabación descartada." else "Esta grabación aún se está procesando y no se puede descartar.")
                }.onFailure { error ->
                    if (error is AccountHttpError && error.status == 401) sessions.logout(session, false)
                    message(if (error is AccountHttpError) "No se pudo descartar la grabación (HTTP ${error.status})."
                        else "No se pudo descartar la grabación. Revisa la conexión e inténtalo de nuevo.")
                }
                render(); sync()
            }
        }
    }

    private fun changed() { AccountSyncJob.schedule(this); render(); sync() }
    private fun sync() {
        if (syncing) return
        syncing = true
        AccountSync.run(applicationContext) { error -> runOnUiThread {
            syncing = false
            if (!active) return@runOnUiThread
            status = when (error) {
                null -> if (sessions.current() != null) AgendaCopy.syncedAt(java.time.LocalTime.now()) else ""
                is AccountHttpError -> if (error.status == 401) { player?.release(); player = null; "La sesión expiró. Vuelve a entrar para continuar." } else "Sincronización en pausa (HTTP ${error.status}). Los cambios se quedan en este teléfono."
                else -> "Sincronización en pausa. Los cambios en cola se reintentan cuando haya conexión."
            }
            render()
        } }
    }
    private fun chooseProject(cal: AccountCalendar, current: AccountProject?, choose: (AccountProject?) -> Unit) {
        val options = (cal.projects() + listOfNotNull(current)).distinctBy { it.id }
        val duplicates = options.groupBy { it.name.lowercase(java.util.Locale.ROOT) }
        val labels = options.map { p ->
            if (duplicates.getValue(p.name.lowercase(java.util.Locale.ROOT)).size > 1) "${p.name} · ${p.id.toString().take(8)}"
            else p.name
        } + listOf("Sin proyecto", "+ Nuevo proyecto")
        dialog().setTitle("Elige un proyecto de la cuenta").setItems(labels.toTypedArray()) { _, i ->
            when {
                i < options.size -> choose(options[i])
                i == options.size -> choose(null)
                else -> {
                    val name = input("Nombre del proyecto").apply { filters = arrayOf(android.text.InputFilter.LengthFilter(120)) }
                    dialog().setTitle("Nuevo proyecto").setView(ui.fields(ui.field("Nombre del proyecto", name)))
                        .setNegativeButton("Cancelar", null)
                        .setPositiveButton("Usar proyecto") { _, _ ->
                            val value = name.text.toString().trim()
                            val project = runCatching { AccountProject(UUID.randomUUID(), value) }.getOrNull()
                            if (project == null) message("Usa un nombre de 1 a 120 caracteres, sin caracteres de control.")
                            else choose(project)
                        }.showFor(cal)
                }
            }
        }.setNegativeButton("Cancelar", null).showFor(cal)
    }
    private fun edit(cal: AccountCalendar, m: JSONObject?) {
        val zone = ZoneId.systemDefault()
        val now = (day?.atTime(java.time.LocalTime.now(zone))?.atZone(zone)?.toInstant() ?: Instant.now())
            .truncatedTo(java.time.temporal.ChronoUnit.MINUTES)
        val title = input("Título de la reunión", m?.getString("title").orEmpty()).apply {
            filters = arrayOf(android.text.InputFilter.LengthFilter(512))
        }
        val start = input("AAAA-MM-DD HH:mm", local(m?.getString("startAt") ?: now.toString()))
        val end = input("AAAA-MM-DD HH:mm", local(m?.getString("endAt") ?: now.plusSeconds(1800).toString()))
        val initial = AccountProject.read(m?.optJSONObject("project"))
        var chosen = initial
        var selection: ProjectChange? = null
        lateinit var project: Button
        project = ui.button(OrbitaButton.SECONDARY, "Proyecto · " + (chosen?.name ?: "Sin proyecto")) {
            chooseProject(cal, chosen) { next ->
                chosen = next
                selection = if (initial?.id == next?.id) null else ProjectChange(next)
                project.text = "Proyecto · " + (chosen?.name ?: "Sin proyecto")
            }
        }
        dialog().setTitle(if (m == null) "Nueva reunión" else "Editar reunión")
            .setMessage("Hora local · formato AAAA-MM-DD HH:mm · " + ZoneId.systemDefault())
            .setView(ScrollView(this).apply {
                addView(ui.fields(ui.field("Título", title), ui.field("Inicio", start), ui.field("Fin", end), project))
            }).setNegativeButton("Cancelar", null)
            .setPositiveButton("Guardar") { _, _ -> safely {
                if (sessions.current()?.token != cal.session.token) return@safely
                fun instant(field: EditText, previous: String?): Instant {
                    val text = field.text.toString().trim()
                    if (previous != null && text == local(previous)) return Instant.parse(previous)
                    val time = runCatching { LocalDateTime.parse(text, DateTimeFormatter.ofPattern("uuuu-MM-dd HH:mm")
                        .withResolverStyle(java.time.format.ResolverStyle.STRICT)) }.getOrElse { throw IllegalArgumentException() }
                    val offsets = ZoneId.systemDefault().rules.getValidOffsets(time)
                    require(offsets.size == 1) { "Ambiguous or missing local time" }
                    return time.toInstant(offsets.first())
                }
                val id = m?.getString("id") ?: UUID.randomUUID().toString()
                cal.stage(id, title.text.toString(), instant(start, m?.getString("startAt")),
                    instant(end, m?.getString("endAt")), m?.getInt("revision") ?: 0, false, selection)
                selected = id; changed()
            } }.showFor(cal)
    }
    private fun resolve(cal: AccountCalendar, id: String) {
        val local = cal.pending(id) ?: return
        val current = cal.cached().firstOrNull { it.getString("id") == id }
        val phoneProject = pendingProject(local, current)
        val serverProject = AccountProject.read(current?.optJSONObject("project"))
        if (local.optString("problem") == "unsupported_project") {
            val assignment = phoneProject?.name ?: "Sin proyecto"
            dialog().setTitle("Asignación de proyecto pendiente")
                .setMessage("El servidor de cuenta guardó la reunión sin confirmar «$assignment». El teléfono conservó tu elección.")
                .setPositiveButton("Reintentar asignación") { _, _ -> safely { cal.retryProject(id); changed() } }
                .setNeutralButton("Descartar elección") { _, _ -> cal.discard(id); changed() }
                .setNegativeButton("Más tarde", null).showFor(cal)
            return
        }
        val isDelete = local.optBoolean("deleted")
        val liveServer = current != null && !current.optBoolean("deleted")
        val phoneAction = if (isDelete) "Eliminar «${local.optString("title")}»"
            else "${local.optString("title")} · ${local(local.getString("startAt"))} · ${phoneProject?.name ?: "Sin proyecto"}"
        val summary = "Teléfono: $phoneAction" +
            "\nCuenta: " + if (!liveServer) "Eliminada o no disponible" else
                current!!.getString("title") + " · " + local(current.getString("startAt")) + " · " + (serverProject?.name ?: "Sin proyecto")
        val dialog = dialog(danger = isDelete && liveServer).setTitle("Resolver cambio pendiente").setMessage(summary)
            .setNegativeButton("Más tarde", null)
        when {
            isDelete && liveServer -> dialog
                .setNeutralButton("Descartar borrado del teléfono") { _, _ -> cal.discard(id); changed() }
                .setPositiveButton("Eliminar versión actual") { _, _ -> safely { cal.reapply(id); changed() } }
            isDelete -> dialog
                .setPositiveButton("Descartar borrado del teléfono") { _, _ -> cal.discard(id); changed() }
            liveServer -> dialog
                .setNeutralButton("Descartar edición del teléfono") { _, _ -> cal.discard(id); changed() }
                .setPositiveButton("Aplicar cambio del teléfono") { _, _ -> safely { cal.reapply(id); changed() } }
            else -> dialog
                .setNeutralButton("Descartar edición del teléfono") { _, _ -> cal.discard(id); changed() }
                .setPositiveButton("Guardar como reunión nueva") { _, _ -> safely {
                    cal.stage(UUID.randomUUID().toString(), local.getString("title"), Instant.parse(local.getString("startAt")),
                        Instant.parse(local.getString("endAt")), 0, false, phoneProject?.let(::ProjectChange))
                    cal.discard(id); changed()
                } }
        }
        dialog.showFor(cal)
    }
    private fun importMeeting(cal: AccountCalendar) {
        val local = MobileMeetingStore(this).list()
        if (local.isEmpty()) { message("No hay reuniones locales en este teléfono."); return }
        dialog().setTitle("Elige una reunión local para copiar").setItems(local.map { it.title }.toTypedArray()) { _, i ->
            val source = local[i]
            dialog().setTitle("¿Copiar «${source.title}» a esta cuenta?")
                .setMessage("Solo se copian el título y las fechas. La original, el audio, las notas y los proyectos se quedan en este teléfono.")
                .setNegativeButton("Cancelar", null).setPositiveButton("Copiar reunión") { _, _ -> safely {
                    val id = UUID.nameUUIDFromBytes(("local-meeting:" + source.id).toByteArray()).toString()
                    if (cal.cached().any { it.getString("id") == id } || cal.pending(id) != null) {
                        message("Esta reunión ya se copió."); return@safely
                    }
                    val start = Instant.ofEpochMilli(source.scheduledStartAtMs ?: source.createdAtMs)
                    val end = source.scheduledEndAtMs?.let(Instant::ofEpochMilli)?.takeIf { it > start } ?: start.plusSeconds(1800)
                    cal.stage(id, source.title, start, end, 0, false); selected = id; changed()
                } }.show()
        }.show()
    }

    private fun provider(cal: AccountCalendar, localOption: Boolean, chosen: (String?) -> Unit) {
        if (usesStagingMailbox(cal.session.origin)) {
            dialog().setTitle("Grabar en este teléfono")
                .setMessage("La transcripción de voz no está disponible en este servidor. Usa «Enviar tono de prueba» para " +
                    "verificar una grabación sintética en ambos dispositivos.")
                .setPositiveButton("Guardar en el teléfono") { _, _ -> chosen(null) }
                .setNegativeButton("Cancelar", null).showFor(cal)
            return
        }
        val providers = mutableListOf("deepgram", "speechmatics")
        val labels = providers.map { "Subir a mi cuenta y transcribir con " + AgendaCopy.providerName(it) }.toMutableList()
        if (localOption) labels += "Guardar el audio solo en este teléfono"
        dialog().setTitle("¿Dónde va esta grabación?")
            .setItems(labels.toTypedArray()) { _, i -> chosen(providers.getOrNull(i)) }
            .setNegativeButton("Cancelar", null).show()
    }
    private fun chooseRecording(cal: AccountCalendar, m: JSONObject) {
        dialog().setTitle("¿Encender el micrófono del teléfono?")
            .setMessage("Confirma que todas las personas están de acuerdo. Android graba el sonido que llega al micrófono; " +
                "puede faltar el audio de quienes participan a distancia.")
            .setPositiveButton("Tengo su consentimiento") { _, _ -> provider(cal, true) { p ->
                if (cal.media.activeRecording() != null || MobileMeetingStore(this).activeRecording() != null) {
                    message("Detén primero la grabación activa."); return@provider
                }
                consent = {
                    if (sessions.current()?.token == cal.session.token && active) {
                        val draft = cal.media.createDraft(m.getString("title"), sourceEventKey = m.getString("id"))
                        if (p != null) cal.enqueueAudio(m.getString("id"), draft.id, p)
                        if (!MeetingRecordingService.start(this, draft.id, accountScope = cal.session.scope)) message("No se pudo encender el micrófono.")
                        render()
                        timer.postDelayed({ if (active) render() }, 800)
                    }
                }
                // Notifications are asked once alongside the microphone; recording starts whatever that answer is.
                val request = prepareRecordingPermissions()
                if (request.permissions.isEmpty()) startConsented()
                else { micAskedBefore = request.microphoneAskedBefore; requestPermissions(request.permissions, 22) }
            } }.setNegativeButton("Cancelar", null).show()
    }
    private fun startConsented() { val start = consent; consent = null; safely { start?.invoke() } }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code != 22) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            // The permission result can precede onResume. Starting still requires a foreground activity.
            timer.post { if (hasWindowFocus() || active) startConsented() else { consent = null; message("Toca «Grabar esta reunión» otra vez para empezar.") } }
        } else {
            consent = null
            // An empty result means the request was cancelled, not denied.
            if (grants.isNotEmpty() && Manifest.permission.RECORD_AUDIO in permissions && microphoneNeedsSettings(micAskedBefore)) {
                showMicrophoneSettings()
            } else message("No se dio acceso al micrófono.")
        }
    }

    /** Spanish, Orbita-styled counterpart of [showMicrophoneSettingsDialog] for this screen. */
    private fun showMicrophoneSettings() {
        if (isFinishing || isDestroyed) return
        dialog().setTitle("Permite el micrófono")
            .setMessage("Android no volverá a pedir el micrófono. Para grabar con este teléfono, abre los ajustes de Hall-e, " +
                "toca Permisos › Micrófono y elige «Permitir solo mientras se usa la app».")
            .setNegativeButton("Ahora no", null)
            .setPositiveButton("Abrir ajustes") { _, _ ->
                runCatching {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
                }.onFailure { message("Abre Ajustes de Android › Apps › Hall-e para permitir el micrófono.") }
            }
            .show()
    }

    private fun beginAuth(google: Boolean, linked: AccountSession?) {
        if (signing) return
        val server = input("https://tu-servidor-de-cuenta", linked?.origin ?: sessions.lastOrigin)
        val staging = usesStagingMailbox(server.text.toString())
        val email = input("nombre@correo.cl", if (staging && linked == null) "halle-owner@example.test" else "").apply {
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
        }
        val serverField = ui.field("Servidor de cuenta", server)
        val form = if (google) ui.fields(serverField) else ui.fields(serverField, ui.field("Correo", email))
        server.isEnabled = linked == null && !staging
        if (!server.isEnabled) server.setTextColor(OrbitaColors.MUTED)
        dialog().setTitle(if (linked == null) "Entrar a Hall-e" else "Vincular a esta cuenta")
            .setView(form).setNegativeButton("Cancelar", null).setPositiveButton("Continuar") { _, _ -> safely {
                val origin = accountOrigin(server.text.toString())
                sessions.lastOrigin = origin
                val body = JSONObject().put("link", linked != null)
                if (!google) body.put("email", email.text.toString().trim())
                authRequest(origin, if (google) "/auth/browser/start" else "/auth/email/start", body, linked) { result ->
                    if (google) {
                        val rawUrl = result.getString("url")
                        require(isApprovedGoogleAuthUrl(rawUrl))
                        val url = Uri.parse(rawUrl)
                        sessions.browserPending(JSONObject().put("origin", origin).put("pollToken", result.getString("pollToken"))
                            .put("linkedUser", linked?.userId ?: ""))
                        startActivity(Intent(Intent.ACTION_VIEW, url))
                    } else code(origin, result.getString("challengeId"), linked)
                }
            } }.show()
    }
    private fun code(origin: String, challenge: String, linked: AccountSession?) {
        val value = input("Código de un solo uso")
        value.inputType = android.text.InputType.TYPE_CLASS_NUMBER
        val prompt = if (usesStagingMailbox(origin)) "Abre Hall-e Staging Code.command en el Mac e ingresa los ocho dígitos aquí."
            else "Ingresa el código que te llegó por correo"
        dialog().setTitle(prompt).setView(ui.fields(ui.field("Código", value)))
            .setNegativeButton("Cancelar", null).setPositiveButton("Verificar") { _, _ ->
                authRequest(origin, "/auth/email/verify", JSONObject().put("challengeId", challenge)
                    .put("code", value.text.toString().trim()), linked) { complete(origin, it, linked) }
            }.show()
    }
    private fun finishGoogle() {
        if (signing) return
        val pending = sessions.browserPending() ?: return
        val linked = sessions.current()
        if (pending.getString("linkedUser") != (linked?.userId ?: "")) { sessions.browserPending(null); return }
        val origin = pending.getString("origin")
        val field = input("8 dígitos").apply { inputType = android.text.InputType.TYPE_CLASS_NUMBER }
        dialog().setTitle("Confirma el inicio con Google")
            .setMessage("Ingresa el código que muestra tu servidor de cuenta en el navegador.")
            .setView(ui.fields(ui.field("Código de confirmación", field))).setNegativeButton("Cancelar", null).setPositiveButton("Verificar") { _, _ ->
                val code = field.text.toString().trim()
                if (!code.matches(Regex("[0-9]{8}"))) { message("Ingresa los ocho dígitos que aparecen en el navegador."); return@setPositiveButton }
                val body = JSONObject().put("pollToken", pending.getString("pollToken")).put("confirmationCode", code)
                authRequest(origin, "/auth/browser/finish", body, linked) {
                    if (it.has("status")) message("Termina de entrar con Google en tu navegador.")
                    else { sessions.browserPending(null); complete(origin, it, linked) }
                }
            }.show()
    }
    private fun complete(origin: String, result: JSONObject, linked: AccountSession?) {
        val session = AccountSession.from(origin, result)
        if (linked != null && linked.userId != session.userId) throw IllegalStateException()
        if (linked != null && linked.token != session.token) sessions.logout(linked, true)
        sessions.save(session); AccountSyncJob.periodic(this, true); status = "Sesión iniciada."; selected = null; changed()
    }
    private fun authRequest(origin: String, path: String, body: JSONObject, linked: AccountSession?, success: (JSONObject) -> Unit) {
        if (signing) return
        signing = true
        auth.execute {
            val result = runCatching { AccountTransport.request(origin, path, "POST", linked?.token, body) }
            runOnUiThread {
                signing = false
                if (isDestroyed || isFinishing || linked?.token != sessions.current()?.token) return@runOnUiThread
                result.onSuccess { safely { success(it) } }.onFailure { e ->
                    if (e is AccountHttpError && path.endsWith("browser/finish") && e.status in listOf(403, 409, 410)) sessions.browserPending(null)
                    status = when {
                        e is AccountHttpError && e.reason == "invalid_confirmation" -> "El código de confirmación de Google no es correcto. Inténtalo de nuevo."
                        e is AccountHttpError && e.status == 409 -> "Entra con tu método actual y vincula este método de forma explícita."
                        e is AccountHttpError -> "No se pudo iniciar sesión (HTTP ${e.status})."
                        else -> "No se puede conectar con el servidor de cuenta."
                    }
                    render()
                }
            }
        }
    }
    companion object { const val EXTRA_DAY = "accountCalendarDay" }
}

private sealed interface TranscriptLoad {
    object Loading : TranscriptLoad
    object Missing : TranscriptLoad
    data class Failed(val reason: String) : TranscriptLoad
    data class Loaded(val text: String) : TranscriptLoad
}

internal fun isApprovedGoogleAuthUrl(raw: String): Boolean {
    val uri = runCatching { java.net.URI(raw) }.getOrNull() ?: return false
    return uri.scheme == "https" && uri.host == "accounts.google.com" &&
        uri.userInfo == null && uri.port == -1 && uri.rawPath == "/o/oauth2/v2/auth"
}
