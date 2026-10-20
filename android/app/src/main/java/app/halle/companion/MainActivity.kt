package app.halle.companion

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.DatePickerDialog
import android.app.Dialog
import android.app.TimePickerDialog
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import android.media.MediaPlayer
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit

class MainActivity : Activity() {
    private lateinit var store: LocalStore
    private lateinit var repository: CalendarRepository
    private lateinit var root: LinearLayout
    private var selectedDate = LocalDate.now()
    private var eventsForDay: List<MeetingOccurrence> = emptyList()
    private var morningSummary: String? = null
    private var previewMode = false
    private lateinit var meetingStore: MobileMeetingStore
    private var pendingRecordingId: String? = null
    private var mediaPlayer: MediaPlayer? = null
    private var playingMeetingId: String? = null
    private var pendingJoinUrl: String? = null
    private var recordingElapsedView: TextView? = null
    private val sharedRecordingExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "halle-shared-recording").apply { isDaemon = true }
    }
    private val recordingTicker = Handler(Looper.getMainLooper())
    private val tickRecording = object : Runnable {
        override fun run() {
            val active = meetingStore.activeRecording()
            if (active == null) {
                if (recordingElapsedView != null) render()
                return
            }
            recordingElapsedView?.text = "${formatDuration(meetingStore.recordingElapsedMs(active.id) ?: 0)} · Phone microphone only. Other participants may not be captured; audio stays on this phone."
            recordingTicker.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.rgb(245, 247, 245)
        window.navigationBarColor = Color.rgb(245, 247, 245)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        store = LocalStore(this)
        meetingStore = MobileMeetingStore(this)
        meetingStore.recoverInterrupted()
        repository = CalendarRepository(this, store)
        updatePreviewMode(intent)
        intent.getLongExtra(MeetingAlertReceiver.EXTRA_BEGIN, 0).takeIf { it > 0 }?.let { begin ->
            selectedDate = Instant.ofEpochMilli(begin).atZone(ZoneId.systemDefault()).toLocalDate()
        }
        maybeCreateMorningSummary()
        render()
        handleRecordingIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        if (::store.isInitialized) {
            if (!previewMode && pendingRecordingId == null) meetingStore.recoverInterrupted()
            if (selectedDate == LocalDate.now() && !previewMode) maybeCreateMorningSummary()
            refreshEvents()
            if (!previewMode) ReminderScheduler.refresh(this)
            render()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        updatePreviewMode(intent)
        val begin = intent.getLongExtra(MeetingAlertReceiver.EXTRA_BEGIN, 0)
        if (begin > 0) selectedDate = Instant.ofEpochMilli(begin).atZone(ZoneId.systemDefault()).toLocalDate()
        refreshEvents()
        if (!previewMode) ReminderScheduler.refresh(this)
        render()
        handleRecordingIntent(intent)
    }

    private fun maybeCreateMorningSummary() {
        if (previewMode) return
        if (!store.morningSummaryEnabled || !repository.hasPermission()) return
        val hour = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
        if (hour !in 4 until 12 || !store.morningSummaryFor(LocalDate.now())) return
        val now = System.currentTimeMillis()
        val start = LocalDate.now().atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val end = LocalDate.now().plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val today = ReminderPlanner.forLocalDate(repository.events(start, end), LocalDate.now())
        morningSummary = ReminderPlanner.summary(today, now)
    }

    private fun updatePreviewMode(intent: Intent) {
        previewMode = BuildConfig.DEBUG && intent.getBooleanExtra(EXTRA_PREVIEW, false)
        if (BuildConfig.DEBUG) {
            store.previewActive = previewMode
            if (previewMode) ReminderScheduler.refresh(this)
        }
    }

    private fun refreshEvents() {
        if (previewMode) {
            eventsForDay = previewMeetings()
            return
        }
        if (!repository.hasPermission()) { eventsForDay = emptyList(); return }
        runCatching {
            val start = selectedDate.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            val end = selectedDate.plusDays(1).atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
            eventsForDay = ReminderPlanner.forLocalDate(repository.events(start, end), selectedDate)
        }.onFailure { eventsForDay = emptyList() }
    }

    private fun render() {
        val scroll = ScrollView(this).apply { isFillViewport = true; setBackgroundColor(Color.rgb(245, 247, 245)) }
        ViewCompat.setOnApplyWindowInsetsListener(scroll) { view, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(view.paddingLeft, systemBars.top, view.paddingRight, systemBars.bottom)
            insets
        }
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(18), dp(18), dp(28))
        }
        scroll.addView(root)
        setContentView(scroll)
        ViewCompat.requestApplyInsets(scroll)

        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val icon = ImageView(this).apply { setImageResource(R.drawable.hall_e); contentDescription = "Hall-e" }
        header.addView(icon, LinearLayout.LayoutParams(dp(44), dp(44)))
        val titleStack = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(12), 0, 0, 0) }
        titleStack.addView(text("Hall-e", 25, Color.rgb(31, 50, 46), true))
        titleStack.addView(text("A calmer way into your day", 13, Color.rgb(98, 116, 108)))
        header.addView(titleStack, LinearLayout.LayoutParams(0, -2, 1f))
        val settings = button("Settings") { showSettings() }
        header.addView(settings)
        root.addView(header)

        root.addView(space(16))
        if (!previewMode) {
            meetingWorkspace()
            root.addView(space(12))
        }
        if (previewMode) {
            card(Color.rgb(229, 242, 236)) {
                addView(text("Preview · synthetic meetings", 14, Color.rgb(27, 79, 63), true))
                addView(text("Calendar access and meeting reminders are disabled. You can still send an explicit test notification. Preview projects and notes stay in the separate debug app.", 12, Color.rgb(52, 83, 71)))
            }
            root.addView(space(8))
            agendaHeader()
            eventsForDay.forEach { eventCard(it) }
        } else if (!repository.hasPermission()) permissionCard() else {
            if (morningSummary != null) {
                card(Color.rgb(229, 242, 236)) {
                    addView(text("A little morning overview", 16, Color.rgb(27, 79, 63), true))
                    addView(text(morningSummary.orEmpty(), 14, Color.rgb(52, 83, 71)))
                }
                root.addView(space(12))
            }
            agendaHeader()
            if (eventsForDay.isEmpty()) {
                card(Color.WHITE) {
                    addView(text("Nothing on the calendar", 17, Color.rgb(45, 62, 56), true))
                    addView(text("Your day has room to breathe. Add a calendar in Settings if something is missing.", 14, Color.rgb(102, 116, 109)))
                }
            } else eventsForDay.forEach { eventCard(it) }
        }
        root.addView(space(16))
        readinessCard()
        root.addView(space(10))
        TextView(this).apply {
            text = "Calendar stays on this device. Pair Hall-e to share selected meeting details and switch the recording device. Audio stays where it was recorded."
            textSize = 12f; setTextColor(Color.rgb(108, 122, 115)); gravity = Gravity.CENTER
            setPadding(dp(8), dp(8), dp(8), dp(8))
        }.also { root.addView(it) }
    }

    private fun permissionCard() {
        card(Color.WHITE) {
            addView(text("Bring your calendar into Hall-e", 19, Color.rgb(38, 58, 50), true))
            addView(text("Hall-e reads selected calendars on this phone to show today’s agenda and schedule local reminders. Events stay on your device.", 14, Color.rgb(99, 114, 106)))
            val grant = button("Choose calendar access") { requestCalendarPermission() }
            addView(grant, LinearLayout.LayoutParams(-1, dp(46)))
        }
    }

    private fun agendaHeader() {
        val line = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL; orientation = LinearLayout.HORIZONTAL }
        line.addView(text(selectedDate.format(DateTimeFormatter.ofPattern("EEEE, MMM d", Locale.getDefault())), 21,
            Color.rgb(38, 58, 50), true), LinearLayout.LayoutParams(0, -2, 1f))
        line.addView(button("‹") { selectedDate = selectedDate.minusDays(1); refreshEvents(); render() })
        line.addView(button("Today") { selectedDate = LocalDate.now(); refreshEvents(); render() })
        line.addView(button("›") { selectedDate = selectedDate.plusDays(1); refreshEvents(); render() })
        root.addView(line)
        root.addView(space(8))
    }

    private fun eventCard(event: MeetingOccurrence) {
        card(Color.WHITE) {
            val top = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.TOP }
            val times = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }
            if (event.allDay) {
                times.addView(text("ALL DAY", 12, Color.rgb(20, 125, 114), true))
            } else {
                times.addView(text(event.startsAt(), 12, Color.rgb(20, 125, 114), true))
                times.addView(text("to ${event.endsAt()}", 11, Color.rgb(108, 121, 114)))
            }
            top.addView(times, LinearLayout.LayoutParams(dp(112), -2))
            val heading = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }
            heading.addView(text(event.title, 17, Color.rgb(39, 55, 49), true))
            heading.addView(text(event.calendarName + (event.location?.takeIf(String::isNotBlank)?.let { " · $it" } ?: ""),
                12, Color.rgb(108, 121, 114)))
            store.projectFor(event.eventKey)?.let { heading.addView(text("Project · $it", 12, Color.rgb(20, 125, 114), true)) }
            top.addView(heading, LinearLayout.LayoutParams(0, -2, 1f))
            addView(top)
            val actions = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            if (event.meetingUrl != null) actions.addView(button("Join") { chooseJoinMode(event) })
            if (!previewMode) actions.addView(button("Open") { openCalendarEvent(event) })
            actions.addView(button("Project") { chooseProject(event) })
            actions.addView(button(if (store.noteFor(event.eventKey).isBlank()) "Note" else "Edit note") { editNote(event) })
            if (store.noteFor(event.eventKey).isNotBlank()) actions.addView(button("Share") { shareNote(event) })
            addView(actions)
        }
        root.addView(space(9))
    }

    private fun meetingWorkspace() {
        val active = meetingStore.activeRecording()
        card(if (active != null) Color.rgb(255, 241, 222) else Color.rgb(229, 242, 236)) {
            addView(text("Meetings on this phone", 18, Color.rgb(31, 58, 48), true))
            meetingStore.loadError?.let {
                addView(text(it, 13, Color.rgb(153, 70, 53), true))
            }
            addView(text("Create a meeting without calendar access, then choose whether to record with this phone’s microphone.",
                13, Color.rgb(76, 99, 87)))
            addView(button("Shared sessions") {
                startActivity(Intent(this@MainActivity, SharedSessionActivity::class.java))
            }, LinearLayout.LayoutParams(-1, dp(44)))
            addView(button("＋  New meeting") { showCreateMeeting() }, LinearLayout.LayoutParams(-1, dp(48)))
            if (active != null) {
                addView(space(7))
                addView(text("Recording · ${active.title}", 15, Color.rgb(133, 73, 20), true))
                recordingElapsedView = text("${formatDuration(meetingStore.recordingElapsedMs(active.id) ?: 0)} · Phone microphone only. Other participants may not be captured; audio stays on this phone.",
                    12, Color.rgb(133, 73, 20)).also { addView(it) }
                addView(button("Stop recording") { stopRecording() })
                recordingTicker.removeCallbacks(tickRecording)
                recordingTicker.postDelayed(tickRecording, 1000)
            } else {
                recordingTicker.removeCallbacks(tickRecording)
                recordingElapsedView = null
            }
        }
        meetingStore.list().forEach { meeting ->
            card(Color.WHITE) {
                addView(text(meeting.title, 16, Color.rgb(39, 55, 49), true))
                val time = meeting.scheduledStartAtMs?.let { Instant.ofEpochMilli(it).atZone(ZoneId.systemDefault())
                    .format(DateTimeFormatter.ofPattern("EEE, MMM d · h:mm a", Locale.getDefault())) }
                addView(text(listOfNotNull(time, meeting.projectName?.let { "Project · $it" }, meetingStatus(meeting)).joinToString("  ·  "),
                    12, Color.rgb(95, 111, 102)))
                meeting.error?.let { addView(text(it, 12, Color.rgb(153, 70, 53))) }
                val actions = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
                if (meeting.status == MobileMeetingStatus.DRAFT) {
                    actions.addView(button("Record") { requestRecording(meeting.id) })
                    actions.addView(button("Save without recording") { toast("Meeting saved on this phone.") })
                }
                if ((meeting.status == MobileMeetingStatus.RECORDED || meeting.status == MobileMeetingStatus.INTERRUPTED) &&
                    meetingStore.playbackUri(meeting.id) != null) {
                    actions.addView(button(if (playingMeetingId == meeting.id) "Stop playback" else "Play") { togglePlayback(meeting) })
                    actions.addView(button("Share audio") { shareRecording(meeting) })
                }
                if (meeting.status == MobileMeetingStatus.INTERRUPTED && meetingStore.sharePartialFileIntent(meeting.id) != null) {
                    actions.addView(button("Share partial file…") { sharePartialRecordingFile(meeting) })
                }
                actions.addView(button("Project") { chooseMeetingProject(meeting) })
                addView(actions)
            }
        }
    }

    private fun showCreateMeeting(event: MeetingOccurrence? = null, shouldRecord: Boolean = false) {
        if (previewMode) return
        val now = System.currentTimeMillis()
        val defaultStart = event?.beginMillis?.takeIf { it > now } ?: now + TimeUnit.MINUTES.toMillis(5)
        val defaultEnd = event?.endMillis?.takeIf { it > defaultStart } ?: defaultStart + TimeUnit.MINUTES.toMillis(30)
        var startAt = defaultStart
        var endAt = defaultEnd
        var project = event?.let { store.projectFor(it.eventKey) }
        val fields = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(8), dp(20), 0) }
        val titleInput = EditText(this).apply { hint = "Meeting title"; setSingleLine(true); setText(event?.title.orEmpty()) }
        val dateButton = button("") {}
        val startButton = button("") {}
        val endButton = button("") {}
        val projectButton = button("") {}
        fun refreshLabels() {
            val formatter = DateTimeFormatter.ofPattern("EEE, MMM d", Locale.getDefault())
            dateButton.text = Instant.ofEpochMilli(startAt).atZone(ZoneId.systemDefault()).format(formatter)
            startButton.text = "Starts · " + Instant.ofEpochMilli(startAt).atZone(ZoneId.systemDefault())
                .format(DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault()))
            endButton.text = "Ends · " + Instant.ofEpochMilli(endAt).atZone(ZoneId.systemDefault())
                .format(DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault()))
            projectButton.text = "Project · ${project ?: "None"}"
        }
        dateButton.setOnClickListener {
            val date = Instant.ofEpochMilli(startAt).atZone(ZoneId.systemDefault()).toLocalDate()
            DatePickerDialog(this, { _, year, month, day ->
                val oldStart = Instant.ofEpochMilli(startAt).atZone(ZoneId.systemDefault())
                val oldEnd = Instant.ofEpochMilli(endAt).atZone(ZoneId.systemDefault())
                val nextDate = LocalDate.of(year, month + 1, day)
                startAt = nextDate.atTime(oldStart.hour, oldStart.minute).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                endAt = nextDate.atTime(oldEnd.hour, oldEnd.minute).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
                refreshLabels()
            }, date.year, date.monthValue - 1, date.dayOfMonth).show()
        }
        startButton.setOnClickListener { pickMeetingTime(startAt) { value -> startAt = value; if (endAt < startAt) endAt = startAt + TimeUnit.MINUTES.toMillis(30); refreshLabels() } }
        endButton.setOnClickListener { pickMeetingTime(endAt) { value -> endAt = maxOf(value, startAt); refreshLabels() } }
        projectButton.setOnClickListener {
            val projects = store.projects()
            val choices = projects + listOf("+ New project", "None")
            android.app.AlertDialog.Builder(this).setTitle("Choose project").setItems(choices.toTypedArray()) { _, index ->
                when { index < projects.size -> project = projects[index]; index == projects.size -> createLocalProject { project = it }
                    else -> project = null }
                refreshLabels()
            }.show()
        }
        fields.addView(titleInput); fields.addView(dateButton); fields.addView(startButton); fields.addView(endButton); fields.addView(projectButton)
        refreshLabels()
        val dialog = android.app.AlertDialog.Builder(this).setTitle("New meeting").setView(fields)
            .setPositiveButton("Save and record", null)
            .setNeutralButton("Save without recording", null)
            .setNegativeButton("Cancel", null).create()
        dialog.setOnShowListener {
            dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val title = titleInput.text.toString().trim().ifBlank { event?.title.orEmpty() }
                if (title.isBlank()) { titleInput.error = "Enter a meeting title"; return@setOnClickListener }
                val meeting = runCatching {
                    meetingStore.createDraft(title, project, event?.eventKey, startAt, endAt)
                }.getOrElse {
                    toast(it.message ?: "Could not save this meeting.")
                    return@setOnClickListener
                }
                dialog.dismiss(); render()
                pendingJoinUrl = if (shouldRecord) event?.meetingUrl else null
                requestRecording(meeting.id)
            }
            dialog.getButton(android.app.AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
                val title = titleInput.text.toString().trim().ifBlank { event?.title.orEmpty() }
                if (title.isBlank()) { titleInput.error = "Enter a meeting title"; return@setOnClickListener }
                val meeting = runCatching {
                    meetingStore.createDraft(title, project, event?.eventKey, startAt, endAt, null)
                }.getOrElse {
                    toast(it.message ?: "Could not save this meeting.")
                    return@setOnClickListener
                }
                dialog.dismiss(); render()
                shareSavedDraftIfPaired(meeting)
            }
        }
        dialog.show()
    }

    private fun pickMeetingTime(current: Long, onPicked: (Long) -> Unit) {
        val time = Instant.ofEpochMilli(current).atZone(ZoneId.systemDefault())
        TimePickerDialog(this, { _, hour, minute ->
            onPicked(time.toLocalDate().atTime(hour, minute).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli())
        }, time.hour, time.minute, false).show()
    }

    private fun createLocalProject(onCreated: (String) -> Unit) {
        val input = EditText(this).apply { hint = "Project name"; setSingleLine(true) }
        android.app.AlertDialog.Builder(this).setTitle("New local project").setView(input)
            .setPositiveButton("Create") { _, _ -> store.addProject(input.text.toString()).takeIf(String::isNotBlank)?.let(onCreated) }
            .setNegativeButton("Cancel", null).show()
    }

    private fun shareSavedDraftIfPaired(meeting: MobileMeeting) {
        val client = SharedSessionClient(this)
        if (!client.paired()) return
        sharedRecordingExecutor.execute {
            val result = runCatching { client.createSession(meeting) }
            runOnUiThread {
                result.onSuccess { toast("Meeting saved locally and shared with paired devices.") }
                    .onFailure { toast("Meeting saved on this phone, but sharing failed: " + (it.message ?: "coordinator unavailable")) }
            }
        }
    }

    private fun chooseJoinMode(event: MeetingOccurrence) {
        android.app.AlertDialog.Builder(this).setTitle("Join ${event.title}")
            .setItems(arrayOf("Join and record with this phone", "Join without recording")) { _, which ->
                if (which == 0) showCreateMeeting(event, shouldRecord = true) else event.meetingUrl?.let(::openMeeting)
            }.setNegativeButton("Cancel", null).show()
    }

    private fun requestRecording(id: String) {
        if (previewMode) return
        if (meetingStore.activeRecording() != null) { toast("Stop the active recording before starting another."); return }
        android.app.AlertDialog.Builder(this).setTitle("Record with this phone?")
            .setMessage("Hall-e records audio from this phone’s microphone only. It may not capture remote participants, and other audio apps may affect recording quality. Recording can require everyone’s consent.")
            .setPositiveButton("Continue") { _, _ ->
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    pendingRecordingId = id
                    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
                } else startRecording(id)
            }.setNegativeButton(if (pendingJoinUrl != null) "Join without recording" else "Not now") { _, _ ->
                pendingJoinUrl?.let(::openMeeting)
                pendingJoinUrl = null
            }.show()
    }

    private fun startRecording(id: String) {
        pendingRecordingId = null
        if (meetingStore.find(id) == null) {
            toast("Could not start recording. Check microphone access and available storage.")
            return
        }
        val client = SharedSessionClient(this)
        if (!client.paired()) {
            startLocalRecording(id, null)
            return
        }
        if (!SharedSessionClient.beginRecordingPreparation()) {
            toast("A shared recording is already being prepared on this phone.")
            return
        }
        pendingRecordingId = id
        render()
        sharedRecordingExecutor.execute {
            val result = runCatching {
                val meeting = meetingStore.find(id) ?: error("Meeting not found.")
                val state = client.state()
                val sessionId = meeting.sharedSessionId ?: meeting.id
                if (state.sessions.none { it.id == sessionId }) client.createSession(meeting)
                client.claimRecordingLease(sessionId)
            }
            runOnUiThread {
                pendingRecordingId = null
                result.onSuccess { lease ->
                    if (isFinishing || isDestroyed || !hasWindowFocus()) {
                        SharedSessionClient.finishRecordingPreparation()
                        sharedRecordingExecutor.execute {
                            runCatching { SharedSessionClient(this).finalizeSegmentAndRelease(lease, "interrupted") }
                        }
                        toast("Recording was not started because Hall-e left the foreground.")
                    } else startLocalRecording(id, lease)
                }
                    .onFailure { error ->
                        SharedSessionClient.finishRecordingPreparation()
                        toast(error.message ?: "Could not get the shared recording lease.")
                        render()
                    }
            }
        }
    }

    private fun handleRecordingIntent(source: Intent?) {
        if (previewMode) return
        val id = source?.getStringExtra(EXTRA_START_RECORDING) ?: return
        source.removeExtra(EXTRA_START_RECORDING)
        if (meetingStore.find(id) != null) requestRecording(id)
    }

    private fun startLocalRecording(id: String, sharedLease: SharedRecordingLease?) {
        val deadline = sharedLease?.let { LeaseDeadline(it.localDeadlineElapsedMs) }
        val started = MeetingRecordingService.start(
            this, id, deadline?.let { guard -> { guard.isValid() } }, sharedLease,
        )
        if (!started) {
            if (sharedLease != null) SharedSessionClient.finishRecordingPreparation()
            if (sharedLease != null) sharedRecordingExecutor.execute {
                runCatching { SharedSessionClient(this).finalizeSegmentAndRelease(sharedLease, "interrupted") }
            }
            toast("Could not start recording. Check microphone access and available storage.")
        } else {
            sharedRecordingExecutor.execute {
                val deadline = android.os.SystemClock.elapsedRealtime() + 3_000L
                var recording = false
                while (android.os.SystemClock.elapsedRealtime() < deadline) {
                    val status = meetingStore.find(id)?.status
                    if (status == MobileMeetingStatus.RECORDING) { recording = true; break }
                    if (status == MobileMeetingStatus.FAILED || status == MobileMeetingStatus.INTERRUPTED) break
                    Thread.sleep(100)
                }
                runOnUiThread {
                    if (sharedLease != null) SharedSessionClient.finishRecordingPreparation()
                    val foreground = !isFinishing && !isDestroyed && hasWindowFocus()
                    if (recording && foreground) {
                        toast(if (sharedLease == null) "Recording with this phone’s microphone. Other participants may not be captured."
                            else "Shared recording is active on this phone only. Other participants may not be captured.")
                        pendingJoinUrl?.let(::openMeeting)
                        pendingJoinUrl = null
                    } else {
                        if (started) {
                            sharedLease?.cancellationRequested?.set(true)
                            MeetingRecordingService.requestStop(this, id,
                                if (!foreground) "activity-backgrounded" else "startup-ack-timeout")
                        }
                        pendingJoinUrl = null
                        toast(if (!foreground) "Recording stopped because Hall-e left the foreground."
                            else "Android could not confirm microphone startup. The recording was safely stopped.")
                    }
                    render()
                }
            }
        }
        render()
    }

    private fun stopRecording() {
        MeetingRecordingService.stop(this)
        recordingTicker.removeCallbacks(tickRecording)
        render()
    }

    private fun togglePlayback(meeting: MobileMeeting) {
        if (playingMeetingId == meeting.id) {
            mediaPlayer?.release(); mediaPlayer = null; playingMeetingId = null; render(); return
        }
        mediaPlayer?.release(); mediaPlayer = null; playingMeetingId = null
        val uri = meetingStore.playbackUri(meeting.id) ?: run { toast("Recording file is unavailable."); return }
        runCatching {
            MediaPlayer().apply {
                setDataSource(this@MainActivity, uri)
                setOnCompletionListener { it.release(); if (playingMeetingId == meeting.id) { playingMeetingId = null; mediaPlayer = null; render() } }
                prepare(); start()
            }
        }.onSuccess { mediaPlayer = it; playingMeetingId = meeting.id; render() }
            .onFailure { toast("Could not play this recording.") }
    }

    private fun shareRecording(meeting: MobileMeeting) {
        val intent = meetingStore.shareIntent(meeting.id) ?: run { toast("Recording file is unavailable."); return }
        startActivity(Intent.createChooser(intent, "Share ${meeting.title}"))
    }

    private fun sharePartialRecordingFile(meeting: MobileMeeting) {
        val intent = meetingStore.sharePartialFileIntent(meeting.id)
            ?: run { toast("Partial recording file is unavailable."); return }
        android.app.AlertDialog.Builder(this)
            .setTitle("Share partial recording file?")
            .setMessage("This file was interrupted before recording completed. Its audio format may be incomplete or unplayable. Hall-e will share the original file only after you choose a destination.")
            .setPositiveButton("Choose destination") { _, _ ->
                startActivity(Intent.createChooser(intent, "Share partial file · ${meeting.title}"))
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun chooseMeetingProject(meeting: MobileMeeting) {
        val projects = store.projects()
        val choices = projects + listOf("+ New project", "Unclassified")
        android.app.AlertDialog.Builder(this).setTitle("Project for ${meeting.title}").setItems(choices.toTypedArray()) { _, index ->
            when {
                index < projects.size -> updateMeetingProject(meeting, projects[index])
                index == projects.size -> createLocalProject { updateMeetingProject(meeting, it) }
                else -> updateMeetingProject(meeting, null)
            }
        }.setNegativeButton("Cancel", null).show()
    }

    private fun updateMeetingProject(meeting: MobileMeeting, projectName: String?) {
        val client = SharedSessionClient(this)
        val sessionId = meeting.sharedSessionId
        if (sessionId == null || !client.paired()) {
            meetingStore.updateProject(meeting.id, projectName)
            render()
            return
        }
        sharedRecordingExecutor.execute {
            val result = runCatching {
                val current = client.state().sessions.firstOrNull { it.id == sessionId }
                    ?: error("The shared meeting is unavailable. Refresh shared sessions before changing its project.")
                check(!current.decryptionFailed) { "The shared meeting could not be decrypted; its project was not changed." }
                client.updateSessionProject(sessionId, projectName, current.revision)
            }
            runOnUiThread {
                result.onSuccess { toast("Project updated for the shared meeting.") }
                    .onFailure { toast(it.message ?: "Could not update the shared meeting project.") }
                render()
            }
        }
    }

    private fun meetingStatus(meeting: MobileMeeting): String = when (meeting.status) {
        MobileMeetingStatus.DRAFT -> "Saved without recording"
        MobileMeetingStatus.STARTING -> "Starting recording"
        MobileMeetingStatus.RECORDING -> "Recording · ${formatDuration(meetingStore.recordingElapsedMs(meeting.id) ?: 0)}"
        MobileMeetingStatus.RECORDED -> "Recorded · ${formatDuration(meeting.durationMs)}"
        MobileMeetingStatus.INTERRUPTED -> "Interrupted · ${formatDuration(meeting.durationMs)}"
        MobileMeetingStatus.FAILED -> "Recording failed"
    }

    private fun formatDuration(ms: Long): String {
        val seconds = (ms.coerceAtLeast(0) / 1000)
        return "%d:%02d".format(Locale.getDefault(), seconds / 60, seconds % 60)
    }

    private fun readinessCard() {
        card(Color.rgb(236, 240, 237)) {
            addView(text("Reminders & privacy", 16, Color.rgb(40, 58, 50), true))
            addView(text("${alertDescription(store.alertMinutes)} · Morning overview ${if (store.morningSummaryEnabled) "on" else "off"}",
                13, Color.rgb(93, 109, 101)))
            if (store.morningSummaryEnabled) addView(text(
                "Morning overview appears on the first app open from 04:00 until noon local time. Android may not open Hall-e before you unlock or launch it.",
                12, Color.rgb(93, 109, 101)))
            val notifications = Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            val alarmManager = getSystemService(AlarmManager::class.java)
            val exact = Build.VERSION.SDK_INT < 31 || alarmManager?.canScheduleExactAlarms() == true
            val status = "Notifications ${if (notifications) "ready" else "need permission"} · Exact alarms ${if (exact) "ready" else "need Settings access"}"
            addView(text(status, 12, if (notifications && exact) Color.rgb(42, 106, 75) else Color.rgb(153, 97, 32)))
            val controls = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL }
            controls.addView(button("Reminder settings") { showSettings() })
            if (!notifications) controls.addView(button("Allow notifications") { requestNotificationPermission() })
            if (!exact) controls.addView(button("Exact alarm access") { openExactAlarmSettings() })
            addView(controls)
        }
    }

    private fun showSettings() {
        val items = mutableListOf<String>()
        val actions = mutableListOf<() -> Unit>()
        if (!previewMode) {
            items += "Choose calendars"
            actions += { chooseCalendars() }
        }
        items += "Reminder timing"; actions += { chooseReminderTiming() }
        items += "Notification permission"; actions += { requestNotificationPermission() }
        items += "Exact alarm access"; actions += { openExactAlarmSettings() }
        items += "Morning overview: ${if (store.morningSummaryEnabled) "On" else "Off"}"
        actions += { store.morningSummaryEnabled = !store.morningSummaryEnabled; render() }
        items += "Send a test notification"; actions += { sendTestNotification() }
        android.app.AlertDialog.Builder(this).setTitle("Hall-e settings")
            .setItems(items.toTypedArray()) { _, which -> actions.getOrNull(which)?.invoke() }
            .setNegativeButton("Done", null).show()
    }

    private fun sendTestNotification() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestNotificationPermission()
            return
        }
        val managerCompat = NotificationManagerCompat.from(this)
        if (!managerCompat.areNotificationsEnabled()) {
            toast("Notifications are disabled for Hall-e in Android Settings.")
            return
        }
        if (Build.VERSION.SDK_INT >= 26) {
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(NotificationChannel(MeetingAlertReceiver.CHANNEL_ID,
                "Meeting reminders", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Local reminders for selected calendar meetings" })
            if (manager?.getNotificationChannel(MeetingAlertReceiver.CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE) {
                toast("Meeting reminders are turned off in Android Settings.")
                return
            }
        }
        runCatching {
            managerCompat.notify(TEST_NOTIFICATION_ID, NotificationCompat.Builder(this, MeetingAlertReceiver.CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle("Hall-e test notification")
                .setContentText("If you can see this, Hall-e can post a notification.")
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .build())
        }.onSuccess { toast("Test notification sent.") }
            .onFailure { toast("Could not send a notification. Check Hall-e's notification settings.") }
    }

    private fun chooseCalendars() {
        if (previewMode) return
        if (!repository.hasPermission()) { requestCalendarPermission(); return }
        val choices = repository.calendars()
        if (choices.isEmpty()) { toast("No calendars are available on this device."); return }
        val selected = store.selectedCalendarIds.toMutableSet()
        val checks = choices.map { it.id in selected }.toBooleanArray()
        val labels = choices.map { "${it.name}\n${it.account}" }.toTypedArray()
        android.app.AlertDialog.Builder(this).setTitle("Calendars to show")
            .setMultiChoiceItems(labels, checks) { _, index, checked ->
                if (checked) selected += choices[index].id else selected -= choices[index].id
            }.setPositiveButton("Save") { _, _ ->
                store.selectedCalendarIds = selected
                refreshEvents(); ReminderScheduler.refresh(this); render()
            }.setNegativeButton("Cancel", null).show()
    }

    private fun chooseReminderTiming() {
        val options = listOf(0, 1, 5, 10, 15, 30)
        val labels = options.map {
            when (it) {
                0 -> "At meeting start"
                1 -> "1 minute before"
                else -> "$it minutes before"
            }
        }.toMutableList().apply { add("Custom…") }
        android.app.AlertDialog.Builder(this).setTitle("Meeting reminder")
            .setSingleChoiceItems(labels.toTypedArray(), options.indexOf(store.alertMinutes).takeIf { it >= 0 } ?: 6) { dialog, index ->
                if (index < options.size) {
                    store.alertMinutes = options[index]
                    dialog.dismiss(); if (!previewMode) ReminderScheduler.refresh(this); render()
                } else {
                    dialog.dismiss(); chooseCustomReminder()
                }
            }.setNegativeButton("Cancel", null).show()
    }

    private fun chooseCustomReminder() {
        val input = EditText(this).apply { inputType = InputType.TYPE_CLASS_NUMBER; hint = "Minutes before (1–1440)"; setText(store.alertMinutes.toString()) }
        android.app.AlertDialog.Builder(this).setTitle("Custom reminder").setView(input)
            .setPositiveButton("Save") { _, _ ->
                val value = input.text.toString().toIntOrNull()
                if (value == null || value !in 1..1440) toast("Choose between 1 and 1440 minutes.")
                else { store.alertMinutes = value; if (!previewMode) ReminderScheduler.refresh(this); render() }
            }.setNegativeButton("Cancel", null).show()
    }

    private fun chooseProject(event: MeetingOccurrence) {
        val projects = store.projects().toMutableList()
        val choices = projects + listOf("+ New project", "Unclassified")
        android.app.AlertDialog.Builder(this).setTitle("Project for this meeting")
            .setItems(choices.toTypedArray()) { _, index ->
                when {
                    index < projects.size -> store.assignProject(event.eventKey, projects[index])
                    index == projects.size -> createProject(event)
                    else -> store.assignProject(event.eventKey, null)
                }
                render()
            }.setNegativeButton("Cancel", null).show()
    }

    private fun createProject(event: MeetingOccurrence) {
        val input = EditText(this).apply { hint = "Project name"; setSingleLine(true) }
        android.app.AlertDialog.Builder(this).setTitle("New local project").setView(input)
            .setPositiveButton("Create and assign") { _, _ ->
                val name = store.addProject(input.text.toString())
                if (name.isNotEmpty()) store.assignProject(event.eventKey, name)
                render()
            }.setNegativeButton("Cancel", null).show()
    }

    private fun editNote(event: MeetingOccurrence) {
        val input = EditText(this).apply {
            hint = "A few useful notes…"; gravity = Gravity.TOP; minLines = 5
            setText(store.noteFor(event.eventKey))
        }
        android.app.AlertDialog.Builder(this).setTitle("Local meeting note").setView(input)
            .setPositiveButton("Save") { _, _ -> store.saveNote(event.eventKey, input.text.toString()); render() }
            .setNeutralButton("Share Markdown") { _, _ ->
                store.saveNote(event.eventKey, input.text.toString()); shareNote(event)
            }.setNegativeButton("Cancel", null).show()
    }

    private fun shareNote(event: MeetingOccurrence) {
        val project = store.projectFor(event.eventKey)
        val content = buildString {
            appendLine("# ${event.title}")
            appendLine()
            appendLine("- Date: ${Instant.ofEpochMilli(event.beginMillis).atZone(ZoneId.systemDefault())}")
            appendLine("- Calendar: ${event.calendarName}")
            if (project != null) appendLine("- Project: $project")
            appendLine()
            appendLine(store.noteFor(event.eventKey))
        }
        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
            type = "text/markdown"; putExtra(Intent.EXTRA_SUBJECT, event.title); putExtra(Intent.EXTRA_TEXT, content)
        }, "Share meeting note"))
    }

    private fun openMeeting(url: String) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
            .onFailure { toast("No browser is available to open this meeting.") }
    }

    private fun openCalendarEvent(event: MeetingOccurrence) {
        val intent = Intent(Intent.ACTION_VIEW, ContentUrisCompat.eventUri(event.eventId))
            .putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, event.beginMillis)
            .putExtra(CalendarContract.EXTRA_EVENT_END_TIME, event.endMillis)
        runCatching { startActivity(intent) }.onFailure { toast("No calendar app is available.") }
    }

    private fun requestCalendarPermission() {
        if (previewMode) return
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_CALENDAR), REQUEST_CALENDAR)
    }
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33) ActivityCompat.requestPermissions(this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        else toast("Notifications are controlled in Android Settings.")
    }
    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT >= 31) runCatching {
            startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                Uri.parse("package:$packageName")))
        }.onFailure { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        refreshEvents()
        if (!previewMode && requestCode == REQUEST_CALENDAR && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            repository.calendars()
            maybeCreateMorningSummary()
        }
        if (!previewMode && requestCode == REQUEST_MICROPHONE) {
            val id = pendingRecordingId
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && id != null) startRecording(id)
            else {
                pendingRecordingId = null
                pendingJoinUrl?.let(::openMeeting)
                pendingJoinUrl = null
                toast("Microphone access was not granted. The meeting was saved without recording.")
                render()
            }
        }
        if (!previewMode) ReminderScheduler.refresh(this)
        render()
    }

    private fun previewMeetings(): List<MeetingOccurrence> {
        val zone = ZoneId.systemDefault()
        fun at(hour: Int, minute: Int): Long = selectedDate.atTime(hour, minute).atZone(zone).toInstant().toEpochMilli()
        val dayKey = selectedDate.toEpochDay() * 10
        return listOf(
            MeetingOccurrence(-1, -(dayKey + 1), at(9, 30), at(10, 0), "Design review", "Room 3", false,
                false, false, null, "Preview calendar"),
            MeetingOccurrence(-1, -(dayKey + 2), at(13, 0), at(13, 45), "Project planning", null, false,
                false, false, null, "Preview calendar"),
            MeetingOccurrence(-1, -(dayKey + 3), at(15, 30), at(16, 0), "Weekly check-in", null, false,
                false, false, null, "Preview calendar"),
        )
    }

    private fun alertDescription(minutes: Int): String = if (minutes == 0) "At start" else "$minutes min before"
    private fun button(label: String, action: () -> Unit): Button = Button(this).apply {
        text = label; textSize = 12f; isAllCaps = false; setTextColor(Color.rgb(32, 92, 79)); setOnClickListener { action() }
    }
    private fun text(value: String, size: Int, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = value; textSize = size.toFloat(); setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(3), dp(4), dp(3))
    }
    private fun space(height: Int) = View(this).apply { layoutParams = LinearLayout.LayoutParams(1, dp(height)) }
    private fun card(color: Int, content: LinearLayout.() -> Unit) {
        val view = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(15), dp(14), dp(15), dp(12))
            background = GradientDrawable().apply { setColor(color); cornerRadius = dp(16).toFloat() }
            content()
        }
        root.addView(view, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(9) })
    }
    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    override fun onDestroy() {
        recordingTicker.removeCallbacks(tickRecording)
        mediaPlayer?.release(); mediaPlayer = null; playingMeetingId = null
        super.onDestroy()
    }

    companion object {
        const val EXTRA_PREVIEW = "HALLE_PREVIEW"
        const val EXTRA_START_RECORDING = "HALLE_START_RECORDING"
        private const val REQUEST_CALENDAR = 11
        private const val REQUEST_NOTIFICATIONS = 12
        private const val REQUEST_MICROPHONE = 13
        private const val TEST_NOTIFICATION_ID = 0x4841
    }
}

private object ContentUrisCompat {
    fun eventUri(id: Long): Uri = Uri.withAppendedPath(CalendarContract.Events.CONTENT_URI, id.toString())
}
