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
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        sessions = AccountSessions(this)
        selected = state?.getString("meeting")
        val dayString = if (state == null) intent.getStringExtra(EXTRA_DAY) else state.getString("day")
        day = dayString?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        AccountSyncJob.periodic(this, sessions.current() != null)
    }
    override fun onResume() { super.onResume(); active = true; render(); timer.post(tick) }
    override fun onPause() { player?.release(); player = null; active = false; timer.removeCallbacks(tick); super.onPause() }
    override fun onDestroy() { auth.shutdownNow(); super.onDestroy() }
    override fun onSaveInstanceState(out: Bundle) { super.onSaveInstanceState(out); out.putString("meeting", selected); out.putString("day", day?.toString()) }
    private fun line(value: String, size: Float = 16f) {
        page.addView(TextView(this).apply { text = value; textSize = size; setPadding(0, 10, 0, 10) })
    }
    private fun action(label: String, block: () -> Unit) {
        page.addView(Button(this).apply {
            text = label; isAllCaps = false; setOnClickListener { safely(block) }
        })
    }
    private fun safely(block: () -> Unit) {
        try { block() } catch (_: IllegalArgumentException) { message("Check the server address, meeting title and dates.") }
        catch (_: IllegalStateException) { message("Could not save this change. Check available storage and the pending changes.") }
    }
    private fun message(value: String) { Toast.makeText(this, value, Toast.LENGTH_LONG).show() }
    private fun input(hintText: String, value: String = "") = EditText(this).apply {
        hint = hintText; setSingleLine(); setText(value)
    }
    private fun fields(vararg fields: EditText) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL; setPadding(32, 14, 32, 14); fields.forEach(::addView)
    }

    private fun usesStagingMailbox(origin: String): Boolean = BuildConfig.STAGING && BuildConfig.ACCOUNT_ORIGIN.isNotEmpty() &&
        runCatching { accountOrigin(origin) }.getOrNull() == BuildConfig.ACCOUNT_ORIGIN

    private fun render() {
        if (isFinishing || isDestroyed) return
        val session = sessions.current()
        projectDialogs.filterValues { it != session?.token }.keys.toList().forEach { it.dismiss() }
        page = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(30, 24, 30, 34) }
        setContentView(ScrollView(this).also { scroll ->
            scroll.setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom); insets
            }
            scroll.addView(page)
        })
        line("Hall-e account calendar", 24f)
        if (status.isNotBlank()) line(status, 14f)
        if (sessions.browserPending() != null) {
            action("Enter Google confirmation code") { finishGoogle() }
            action("Cancel Google sign-in") { sessions.browserPending(null); render() }
        }
        if (session == null) {
            selected = null
            line("Sign in to the same account server as your computer. Meetings created here are private to your account.")
            action("Sign in with email") { beginAuth(false, null) }
            if (usesStagingMailbox(sessions.lastOrigin)) {
                line("Request one code per device. Open Hall-e Staging Code.command on the Mac to read it.", 14f)
            } else action("Sign in with Google") { beginAuth(true, null) }
            if (BuildConfig.STAGING) {
                action("Change account server…") {
                    val server = input("HTTPS account server", sessions.lastOrigin)
                    AlertDialog.Builder(this).setTitle("Account server").setView(fields(server))
                        .setNegativeButton("Cancel", null).setPositiveButton("Save") { _, _ -> safely {
                            sessions.lastOrigin = accountOrigin(server.text.toString()); render()
                        } }.show()
                }
            }
            return
        }
        val cal = AccountCalendar(this, session)
        cal.media.recoverInterrupted()
        val rows = cal.visible()
        val meeting = rows.firstOrNull { it.getString("id") == selected }
        if (meeting != null) {
            action("Back to calendar") { selected = null; render() }
            showMeeting(cal, meeting)
            return
        }
        selected = null
        line(session.origin, 14f)
        action("New meeting") { edit(cal, null) }
        action("Sync now") { sync() }
        val chosenDay = day
        val displayed = if (chosenDay == null) rows else {
            val zone = ZoneId.systemDefault()
            val begin = chosenDay.atStartOfDay(zone).toInstant()
            val end = chosenDay.plusDays(1).atStartOfDay(zone).toInstant()
            rows.filter { Instant.parse(it.getString("startAt")) < end && Instant.parse(it.getString("endAt")) > begin }
        }
        action(chosenDay?.let { "Date · " + it } ?: "Choose a date") {
            val date = day ?: LocalDate.now()
            android.app.DatePickerDialog(this, { _, y, month, d -> day = LocalDate.of(y, month+1, d); render() },
                date.year, date.monthValue-1, date.dayOfMonth).show()
        }
        if (chosenDay != null) action("Show all dates") { day = null; render() }
        for (row in displayed) action(row.optString("title").ifBlank { "Deleted meeting" } + "\n" + local(row.getString("startAt")) +
            (AccountProject.read(row.optJSONObject("project"))?.let { " · " + it.name } ?: "")) {
            selected = row.getString("id"); render()
        }
        if (displayed.isEmpty()) line("No account meetings for these dates.")
        for (id in cal.mutationIds()) {
            val pending = cal.pending(id) ?: continue
            if (pending.has("problem")) action("Resolve change · " + pending.getString("title")) { resolve(cal, id) }
        }
        val orphans = cal.orphanedRecordings()
        if (orphans.isNotEmpty()) {
            line("Local phone recordings from deleted meetings", 15f)
            for (orphan in orphans) {
                line(orphan.title + " · " + orphan.status.name.lowercase(), 14f)
                cal.media.completedAudio(orphan.id)?.let { file ->
                    action("Play phone copy · " + orphan.title) { playLocalFile(cal, file) }
                }
                action("Delete phone copy · " + orphan.title) {
                    AlertDialog.Builder(this).setTitle("Delete local phone copy?")
                        .setMessage("This meeting was deleted from your account. Deleting removes the audio file from this phone.")
                        .setNegativeButton("Cancel", null)
                        .setPositiveButton("Delete") { _, _ -> cal.deleteOrphanedRecording(orphan.id); render() }
                        .showFor(cal)
                }
            }
        }
        action("Copy a local meeting…") { importMeeting(cal) }
        if (!usesStagingMailbox(session.origin)) action("Link another sign-in method…") {
            AlertDialog.Builder(this).setTitle("Link to this Hall-e account")
                .setItems(arrayOf("Email code", "Google")) { _, i -> beginAuth(i == 1, session) }.show()
        }
        if (cal.features().accountDeletion) action("Delete account…") { confirmAccountDeletion(cal) }
        action("Sign out") {
            player?.release(); player = null
            cal.media.activeRecording()?.let { MeetingRecordingService.requestStop(this, it.id, "user") }
            sessions.logout(session, true)
            AccountSyncJob.periodic(this, false)
            AccountSyncJob.schedule(this)
            selected = null; status = "Signed out. Pending changes stay on this phone for the same account."
            render()
        }
    }

    private fun local(raw: String): String = Instant.parse(raw).atZone(ZoneId.systemDefault())
        .format(DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))
    private fun showMeeting(cal: AccountCalendar, m: JSONObject) {
        val id = m.getString("id")
        line(m.optString("title"), 21f)
        line("Account project · " + (AccountProject.read(m.optJSONObject("project"))?.name ?: "None"))
        line(local(m.getString("startAt")) + " – " + local(m.getString("endAt")))
        val pending = cal.pending(id)
        if (pending != null) {
            line(if (pending.has("problem")) "This change needs your attention." else "Change queued on this phone.")
            if (pending.has("problem")) action("Review conflict") { resolve(cal, id) }
        } else {
            action("Edit meeting") { edit(cal, m) }
            action("Delete from account…") {
                AlertDialog.Builder(this).setTitle("Delete this meeting and its shared recordings on all devices?")
                    .setNegativeButton("Cancel", null).setPositiveButton("Delete") { _, _ ->
                        safely { cal.stage(id, m.getString("title"), Instant.parse(m.getString("startAt")),
                            Instant.parse(m.getString("endAt")), m.getInt("revision"), true); changed() }
                    }.show()
            }
        }
        if (!m.optBoolean("deleted")) action("Record phone microphone…") { chooseRecording(cal, m) }
        val remote = (m.optJSONArray("recordings") ?: JSONArray()).objects()
        if (!m.optBoolean("deleted") && usesStagingMailbox(cal.session.origin)) {
            val spanish = resources.configuration.locales[0].language == "es"
            action(if (spanish) "Enviar tono de prueba" else "Send test tone") {
                if (sessions.current()?.token == cal.session.token) {
                    try {
                        val bytes = assets.open("phone-tone.mp4").use { it.readBytes() }
                        val sampleId = cal.media.installStagingTone(id, bytes)
                        if (remote.none { it.optString("id") == sampleId } && cal.upload(sampleId) == null) {
                            cal.enqueueAudio(id, sampleId, "deepgram")
                        }
                        changed()
                    } catch (_: java.io.IOException) {
                        message(if (spanish) "No se pudo guardar el tono de prueba." else "Could not save the test tone.")
                    }
                }
            }
        }
        for (r in remote) {
            line("Recording · " + r.getString("status") + (r.optNullableString("detail")?.let { " · $it" } ?: ""))
            val inline = inlineTranscript(r)
            if (inline != null) line(inline) else if (hasRemoteTranscript(r)) showRemoteTranscript(cal, id, r)
            if (isDiscardableRecording(r)) action("Discard recording…") {
                AlertDialog.Builder(this).setTitle("Discard this recording from your account?")
                    .setMessage("The service stopped on this recording. Discarding removes its audio and any transcript draft " +
                        "from your account on all devices. A copy kept on this phone is not deleted.")
                    .setNegativeButton("Cancel", null)
                    .setPositiveButton("Discard") { _, _ -> discardRecording(cal, id, r.getString("id")) }
                    .showFor(cal)
            }
        }
        for (draft in cal.recordings(id)) {
            val queue = cal.upload(draft.id)
            val shared = remote.any { it.getString("id") == draft.id }
            line("Phone recording · " + draft.status.name.lowercase() + when {
                queue?.has("problem") == true -> " · upload needs attention (HTTP ${queue.getInt("problem")})"
                queue != null && usesStagingMailbox(cal.session.origin) -> " · queued for staging"
                queue != null -> " · queued for " + queue.getString("provider")
                shared -> " · uploaded"
                else -> " · local only"
            })
            draft.error?.let { line(it) }
            cal.media.completedAudio(draft.id)?.let { file ->
                action("Play phone copy") { playLocalFile(cal, file) }
            }
            if (queue?.has("problem") == true) {
                action("Retry upload") { cal.retryUpload(draft.id); changed() }
                action("Cancel upload") { cal.discardUpload(draft.id); changed() }
            }
            if (draft.status in setOf(MobileMeetingStatus.STARTING, MobileMeetingStatus.RECORDING)) {
                action("Stop recording") { MeetingRecordingService.requestStop(this, draft.id, "user"); timer.postDelayed({ render() }, 650) }
            } else if (cal.media.completedAudio(draft.id) != null && queue == null && !shared) {
                if (usesStagingMailbox(cal.session.origin)) {
                    line("This recording stays on your phone. Use Send test tone to test staging sync.", 14f)
                } else action("Send this recording for transcription…") {
                    provider(cal, false) { p -> cal.enqueueAudio(id, draft.id, p!!); changed() }
                }
            }
        }
    }

    private fun showRemoteTranscript(cal: AccountCalendar, meetingId: String, recording: JSONObject) {
        val recordingId = recording.getString("id")
        val key = cal.session.scope + "/" + recordingId.lowercase(java.util.Locale.ROOT)
        val state = transcriptLoads[key]
        if (state is TranscriptLoad.Loaded) { line(state.text); return }
        cal.cachedTranscript(recording)?.let { line(it); return }
        when (state) {
            null, TranscriptLoad.Loading -> {
                if (state == null) loadTranscript(cal, meetingId, recordingId, key)
                line("Loading transcript…", 14f)
            }
            TranscriptLoad.Missing -> line("No transcript is stored for this recording.", 14f)
            is TranscriptLoad.Failed -> {
                line(state.reason, 14f)
                action("Retry transcript") { transcriptLoads.remove(key); render() }
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
                        "Could not load the transcript (HTTP ${error.status})." else "Could not load the transcript. Check the connection.")
                }
                render()
            }
        }
    }

    private fun confirmAccountDeletion(cal: AccountCalendar) {
        val typed = input("Type $ACCOUNT_DELETION_CONFIRMATION").apply {
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS
        }
        if (sessions.current()?.token != cal.session.token) return
        val dialog = AlertDialog.Builder(this).setTitle("Delete this Hall-e account?")
            .setMessage("This permanently removes the account's meetings, transcripts and audio from the service " +
                "and signs out every device. It cannot be undone. Recordings on this phone move to your personal library.\n\n" +
                "Type $ACCOUNT_DELETION_CONFIRMATION to confirm.")
            .setView(fields(typed)).setNegativeButton("Cancel", null)
            .setPositiveButton("Delete account") { _, _ ->
                if (isAccountDeletionConfirmed(typed.text.toString())) deleteAccount(cal)
                else message("Type $ACCOUNT_DELETION_CONFIRMATION to delete the account.")
            }.create()
        projectDialogs[dialog] = cal.session.token
        dialog.setOnDismissListener { projectDialogs.remove(dialog) }
        dialog.setOnShowListener {
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
        status = "Deleting account…"
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
                error == null -> "Account deleted. Recordings on this phone move to your personal library."
                error is LocalWipeIncomplete -> "Account deleted. Some of its data cached on this phone could not be removed."
                error is AccountHttpError && error.reason == "deletion_disabled" ->
                    "Account deletion is not available on this server. Nothing was changed."
                error is AccountHttpError && error.status == 401 -> "Session expired. Sign in to continue."
                error is AccountHttpError -> "Could not delete the account (HTTP ${error.status}). Nothing was changed."
                else -> "Could not delete the account. Check the connection; nothing was changed."
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
                message("The phone copy could not be played."); true
            }
            audio.prepareAsync()
        }.onFailure { audio.release(); player = null; message("The phone copy could not be played.") }
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
                    message(if (discarded) "Recording discarded." else "This recording is still being processed and cannot be discarded.")
                }.onFailure { error ->
                    if (error is AccountHttpError && error.status == 401) sessions.logout(session, false)
                    message(if (error is AccountHttpError) "Could not discard the recording (HTTP ${error.status})."
                        else "Could not discard the recording. Check the connection and try again.")
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
                null -> if (sessions.current() != null) "Last synced at " + java.time.LocalTime.now().withNano(0) else ""
                is AccountHttpError -> if (error.status == 401) { player?.release(); player = null; "Session expired. Sign in to continue." } else "Sync paused (HTTP ${error.status}). Changes stay on this phone."
                else -> "Sync paused. Queued changes will retry when connected."
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
        } + listOf("No project", "New account project…")
        AlertDialog.Builder(this).setTitle("Choose an account project").setItems(labels.toTypedArray()) { _, i ->
            when {
                i < options.size -> choose(options[i])
                i == options.size -> choose(null)
                else -> {
                    val name = input("Project name").apply { filters = arrayOf(android.text.InputFilter.LengthFilter(120)) }
                    AlertDialog.Builder(this).setTitle("New account project").setView(fields(name)).setNegativeButton("Cancel", null)
                        .setPositiveButton("Use project") { _, _ ->
                            val value = name.text.toString().trim()
                            val project = runCatching { AccountProject(UUID.randomUUID(), value) }.getOrNull()
                            if (project == null) message("Use a project name of 1–120 characters without control characters.")
                            else choose(project)
                        }.showFor(cal)
                }
            }
        }.setNegativeButton("Cancel", null).showFor(cal)
    }
    private fun edit(cal: AccountCalendar, m: JSONObject?) {
        val zone = ZoneId.systemDefault()
        val now = (day?.atTime(java.time.LocalTime.now(zone))?.atZone(zone)?.toInstant() ?: Instant.now())
            .truncatedTo(java.time.temporal.ChronoUnit.MINUTES)
        val title = input("Meeting title", m?.getString("title").orEmpty()).apply {
            filters = arrayOf(android.text.InputFilter.LengthFilter(512))
        }
        val start = input("Start", local(m?.getString("startAt") ?: now.toString()))
        val end = input("End", local(m?.getString("endAt") ?: now.plusSeconds(1800).toString()))
        val initial = AccountProject.read(m?.optJSONObject("project"))
        var chosen = initial
        var selection: ProjectChange? = null
        val project = Button(this).apply {
            isAllCaps = false
            text = "Account project · " + (chosen?.name ?: "None")
            setOnClickListener { chooseProject(cal, chosen) { next ->
                chosen = next
                selection = if (initial?.id == next?.id) null else ProjectChange(next)
                text = "Account project · " + (chosen?.name ?: "None")
            } }
        }
        AlertDialog.Builder(this).setTitle("Meeting · local time").setMessage("Format: YYYY-MM-DD HH:mm · " + ZoneId.systemDefault())
            .setView(fields(title, start, end).apply { addView(project) }).setNegativeButton("Cancel", null)
            .setPositiveButton("Save") { _, _ -> safely {
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
            val assignment = phoneProject?.name ?: "No project"
            AlertDialog.Builder(this).setTitle("Project assignment pending")
                .setMessage("The account server saved the meeting without confirming “$assignment”. The phone kept your selection.")
                .setPositiveButton("Retry assignment") { _, _ -> safely { cal.retryProject(id); changed() } }
                .setNeutralButton("Discard selection") { _, _ -> cal.discard(id); changed() }
                .setNegativeButton("Later", null).showFor(cal)
            return
        }
        val isDelete = local.optBoolean("deleted")
        val liveServer = current != null && !current.optBoolean("deleted")
        val phoneAction = if (isDelete) "Delete “${local.optString("title")}”"
            else "${local.optString("title")} · ${local(local.getString("startAt"))} · ${phoneProject?.name ?: "No project"}"
        val summary = "Phone: $phoneAction" +
            "\nAccount: " + if (!liveServer) "Deleted or unavailable" else
                current!!.getString("title") + " · " + local(current.getString("startAt")) + " · " + (serverProject?.name ?: "No project")
        val dialog = AlertDialog.Builder(this).setTitle("Resolve pending change").setMessage(summary)
            .setNegativeButton("Later", null)
        when {
            isDelete && liveServer -> dialog
                .setNeutralButton("Discard phone delete") { _, _ -> cal.discard(id); changed() }
                .setPositiveButton("Delete current version") { _, _ -> safely { cal.reapply(id); changed() } }
            isDelete -> dialog
                .setPositiveButton("Discard phone delete") { _, _ -> cal.discard(id); changed() }
            liveServer -> dialog
                .setNeutralButton("Discard phone edit") { _, _ -> cal.discard(id); changed() }
                .setPositiveButton("Apply phone change") { _, _ -> safely { cal.reapply(id); changed() } }
            else -> dialog
                .setNeutralButton("Discard phone edit") { _, _ -> cal.discard(id); changed() }
                .setPositiveButton("Save phone version as new") { _, _ -> safely {
                    cal.stage(UUID.randomUUID().toString(), local.getString("title"), Instant.parse(local.getString("startAt")),
                        Instant.parse(local.getString("endAt")), 0, false, phoneProject?.let(::ProjectChange))
                    cal.discard(id); changed()
                } }
        }
        dialog.showFor(cal)
    }
    private fun importMeeting(cal: AccountCalendar) {
        val local = MobileMeetingStore(this).list()
        if (local.isEmpty()) { message("No local meetings on this phone."); return }
        AlertDialog.Builder(this).setTitle("Choose a local meeting to copy").setItems(local.map { it.title }.toTypedArray()) { _, i ->
            val source = local[i]
            AlertDialog.Builder(this).setTitle("Copy “${source.title}” to this account?")
                .setMessage("Only its title and dates are copied. The original, audio, notes and projects stay on this phone.")
                .setNegativeButton("Cancel", null).setPositiveButton("Copy meeting") { _, _ -> safely {
                    val id = UUID.nameUUIDFromBytes(("local-meeting:" + source.id).toByteArray()).toString()
                    if (cal.cached().any { it.getString("id") == id } || cal.pending(id) != null) {
                        message("This meeting was already copied."); return@safely
                    }
                    val start = Instant.ofEpochMilli(source.scheduledStartAtMs ?: source.createdAtMs)
                    val end = source.scheduledEndAtMs?.let(Instant::ofEpochMilli)?.takeIf { it > start } ?: start.plusSeconds(1800)
                    cal.stage(id, source.title, start, end, 0, false); selected = id; changed()
                } }.show()
        }.show()
    }

    private fun provider(cal: AccountCalendar, localOption: Boolean, chosen: (String?) -> Unit) {
        if (usesStagingMailbox(cal.session.origin)) {
            AlertDialog.Builder(this).setTitle("Record on this phone")
                .setMessage("Speech transcription is unavailable on this server. Use Send test tone to verify a synthetic recording on both devices.")
                .setPositiveButton("Keep on phone") { _, _ -> chosen(null) }
                .setNegativeButton("Cancel", null).showFor(cal)
            return
        }
        val providers = mutableListOf("Deepgram" to "deepgram", "Speechmatics · EU" to "speechmatics")
        val labels = providers.map { "Upload to my account and transcribe with " + it.first }.toMutableList()
        if (localOption) labels += "Keep audio only on this phone"
        AlertDialog.Builder(this).setTitle("Where should this recording go?")
            .setItems(labels.toTypedArray()) { _, i -> chosen(providers.getOrNull(i)?.second) }
            .setNegativeButton("Cancel", null).show()
    }
    private fun chooseRecording(cal: AccountCalendar, m: JSONObject) {
        AlertDialog.Builder(this).setTitle("Start the phone microphone?")
            .setMessage("Confirm that everyone consents. Android records sound at the microphone. Remote meeting audio may be missing.")
            .setPositiveButton("I have consent") { _, _ -> provider(cal, true) { p ->
                if (cal.media.activeRecording() != null || MobileMeetingStore(this).activeRecording() != null) {
                    message("Stop the active recording first."); return@provider
                }
                consent = {
                    if (sessions.current()?.token == cal.session.token && active) {
                        val draft = cal.media.createDraft(m.getString("title"), sourceEventKey = m.getString("id"))
                        if (p != null) cal.enqueueAudio(m.getString("id"), draft.id, p)
                        if (!MeetingRecordingService.start(this, draft.id, accountScope = cal.session.scope)) message("Microphone could not start.")
                        render()
                        timer.postDelayed({ if (active) render() }, 800)
                    }
                }
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) startConsented()
                else requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 22)
            } }.setNegativeButton("Cancel", null).show()
    }
    private fun startConsented() { val start = consent; consent = null; safely { start?.invoke() } }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code == 22 && grants.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            // The permission result can precede onResume. Starting still requires a foreground activity.
            timer.post { if (hasWindowFocus() || active) startConsented() else { consent = null; message("Tap Record again to start.") } }
        } else { consent = null; message("Microphone access was not granted.") }
    }

    private fun beginAuth(google: Boolean, linked: AccountSession?) {
        if (signing) return
        val server = input("https://your-account-server", linked?.origin ?: sessions.lastOrigin)
        val staging = usesStagingMailbox(server.text.toString())
        val email = input("Email address", if (staging && linked == null) "halle-owner@example.test" else "")
        val form = if (google) fields(server) else fields(server, email)
        server.isEnabled = linked == null && !staging
        AlertDialog.Builder(this).setTitle(if (linked == null) "Sign in to Hall-e" else "Link to this account")
            .setView(form).setNegativeButton("Cancel", null).setPositiveButton("Continue") { _, _ -> safely {
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
        val value = input("One-time code")
        value.inputType = android.text.InputType.TYPE_CLASS_NUMBER
        val prompt = if (usesStagingMailbox(origin)) "Open Hall-e Staging Code.command on the Mac and enter the eight digits here."
            else "Enter the code from your email"
        AlertDialog.Builder(this).setTitle(prompt).setView(fields(value))
            .setNegativeButton("Cancel", null).setPositiveButton("Verify") { _, _ ->
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
        val field = input("8-digit confirmation code").apply { inputType = android.text.InputType.TYPE_CLASS_NUMBER }
        AlertDialog.Builder(this).setTitle("Confirm Google sign-in")
            .setMessage("Enter the code displayed by your account server in the browser.")
            .setView(fields(field)).setNegativeButton("Cancel", null).setPositiveButton("Verify") { _, _ ->
                val code = field.text.toString().trim()
                if (!code.matches(Regex("[0-9]{8}"))) { message("Enter the eight digits shown in the browser."); return@setPositiveButton }
                val body = JSONObject().put("pollToken", pending.getString("pollToken")).put("confirmationCode", code)
                authRequest(origin, "/auth/browser/finish", body, linked) {
                    if (it.has("status")) message("Finish signing in with Google in your browser.")
                    else { sessions.browserPending(null); complete(origin, it, linked) }
                }
            }.show()
    }
    private fun complete(origin: String, result: JSONObject, linked: AccountSession?) {
        val session = AccountSession.from(origin, result)
        if (linked != null && linked.userId != session.userId) throw IllegalStateException()
        if (linked != null && linked.token != session.token) sessions.logout(linked, true)
        sessions.save(session); AccountSyncJob.periodic(this, true); status = "Signed in."; selected = null; changed()
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
                        e is AccountHttpError && e.reason == "invalid_confirmation" -> "Incorrect Google confirmation code. Try again."
                        e is AccountHttpError && e.status == 409 -> "Sign in with your existing method and link this method explicitly."
                        e is AccountHttpError -> "Sign-in request failed (HTTP ${e.status})."
                        else -> "Cannot reach the account server."
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
