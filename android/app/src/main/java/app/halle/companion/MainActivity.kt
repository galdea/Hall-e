package app.halle.companion

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.DatePickerDialog
import android.app.Dialog
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

class MainActivity : Activity() {
    private lateinit var store: LocalStore
    private lateinit var repository: CalendarRepository
    private lateinit var root: LinearLayout
    private var selectedDate = LocalDate.now()
    private var eventsForDay: List<MeetingOccurrence> = emptyList()
    private var morningSummary: String? = null
    private var previewMode = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.rgb(245, 247, 245)
        window.navigationBarColor = Color.rgb(245, 247, 245)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        store = LocalStore(this)
        repository = CalendarRepository(this, store)
        updatePreviewMode(intent)
        intent.getLongExtra(MeetingAlertReceiver.EXTRA_BEGIN, 0).takeIf { it > 0 }?.let { begin ->
            selectedDate = Instant.ofEpochMilli(begin).atZone(ZoneId.systemDefault()).toLocalDate()
        }
        maybeCreateMorningSummary()
        render()
    }

    override fun onResume() {
        super.onResume()
        if (::store.isInitialized) {
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
            text = "Calendar stays on this device. Hall-e does not sync this companion with your Mac."
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
            if (event.meetingUrl != null) actions.addView(button("Join") { openMeeting(event.meetingUrl) })
            if (!previewMode) actions.addView(button("Open") { openCalendarEvent(event) })
            actions.addView(button("Project") { chooseProject(event) })
            actions.addView(button(if (store.noteFor(event.eventKey).isBlank()) "Note" else "Edit note") { editNote(event) })
            if (store.noteFor(event.eventKey).isNotBlank()) actions.addView(button("Share") { shareNote(event) })
            addView(actions)
        }
        root.addView(space(9))
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

    companion object {
        const val EXTRA_PREVIEW = "HALLE_PREVIEW"
        private const val REQUEST_CALENDAR = 11
        private const val REQUEST_NOTIFICATIONS = 12
        private const val TEST_NOTIFICATION_ID = 0x4841
    }
}

private object ContentUrisCompat {
    fun eventUri(id: Long): Uri = Uri.withAppendedPath(CalendarContract.Events.CONTENT_URI, id.toString())
}
