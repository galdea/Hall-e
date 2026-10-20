package app.halle.companion

import android.app.Instrumentation
import android.app.Notification
import android.app.NotificationManager
import android.app.ActivityManager
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.SystemClock
import androidx.core.app.NotificationManagerCompat
import java.io.File
import java.util.UUID

/** Device-side regression for the partial-to-final rename and metadata commit boundary. */
class MobileStoreInstrumentation : Instrumentation() {
    private var reminderOnly = false
    private var micStopOnly = false
    private var localReminderOnly = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        reminderOnly = arguments?.getString("screen-reminder") == "true"
        micStopOnly = arguments?.getString("mic-stop") == "true"
        localReminderOnly = arguments?.getString("local-reminder") == "true"
        start()
    }

    override fun onStart() {
        try {
            if (reminderOnly) { verifyScreenReminder(); return }
            if (localReminderOnly) { verifyLocalDraftReminder(); return }
            if (micStopOnly) { verifyMicNotificationStop(); return }
            verifyTransferSchedulingPermission()
            verifyNormalFinalization()
            verifyInterruptedFinalization()
            verifyTrashedDraftCannotRecord()
            verifyHiddenOccurrenceRoundTrip()
            finish(0, Bundle().apply { putString("result", "passed") })
        } catch (failure: Throwable) {
            finish(1, Bundle().apply { putString("failure", failure.toString()) })
            throw failure
        }
    }

    /** Explicit opt-in receiver/PendingIntent test; leaves unrelated alarms and notifications alone. */
    private fun verifyLocalDraftReminder() {
        check(NotificationManagerCompat.from(targetContext).areNotificationsEnabled()) {
            "Local reminder test requires notifications already enabled; no permission or setting was changed."
        }
        val meetings = MobileMeetingStore(targetContext)
        val notificationManager = targetContext.getSystemService(NotificationManager::class.java)
        val now = System.currentTimeMillis()
        val beginsAt = now + 10 * 60_000L
        val title = "ReminderRegression ${UUID.randomUUID()}"
        val postedDraft = meetings.createDraft(title, scheduledStartAtMs = beginsAt, scheduledEndAtMs = beginsAt + 30 * 60_000L)
        val withdrawnDraft = meetings.createDraft("$title withdrawn", scheduledStartAtMs = beginsAt, scheduledEndAtMs = beginsAt + 30 * 60_000L)
        val postedEvent = requireNotNull(ReminderPlanner.localScheduledDrafts(listOf(postedDraft)).singleOrNull())
        val withdrawnEvent = requireNotNull(ReminderPlanner.localScheduledDrafts(listOf(withdrawnDraft)).singleOrNull())
        try {
            val defaultLeadMinutes = ReminderPlanner.DEFAULT_ALERT_MINUTES
            val triggerAt = requireNotNull(ReminderPlanner.alertAt(postedEvent, defaultLeadMinutes))
            check(defaultLeadMinutes == 10 && triggerAt == beginsAt - 10 * 60_000L) {
                "Local draft reminder default was not planned exactly 10 minutes before start"
            }
            check(ReminderPlanner.eligible(listOf(postedEvent), defaultLeadMinutes, now).single().second <= now + 1_000L) {
                "A reminder whose ten-minute trigger is now was not scheduled promptly"
            }

            // Sending the immutable PendingIntent exercises actual receiver delivery and notification posting.
            ReminderScheduler.pendingIntent(targetContext, postedEvent, 0).send()
            val posted = awaitNotification(postedEvent.occurrenceId.hashCode(), 3_000L)
            check(posted != null && posted.extras?.getString(Notification.EXTRA_TITLE)?.contains(title) == true) {
                "MeetingAlertReceiver did not post the local-draft reminder notification"
            }

            check(meetings.trash(withdrawnDraft.id)) { "Could not withdraw the generated reminder test draft" }
            ReminderScheduler.pendingIntent(targetContext, withdrawnEvent, 0).send()
            Thread.sleep(500)
            check(activeNotification(withdrawnEvent.occurrenceId.hashCode()) == null) {
                "A withdrawn local draft still produced a reminder notification"
            }
        } finally {
            ReminderScheduler.cancel(targetContext, postedEvent.occurrenceId)
            ReminderScheduler.cancel(targetContext, withdrawnEvent.occurrenceId)
            notificationManager?.cancel(postedEvent.occurrenceId.hashCode())
            notificationManager?.cancel(withdrawnEvent.occurrenceId.hashCode())
            // Store has no hard-delete API; mark only these generated drafts trashed for suppression.
            meetings.trash(postedDraft.id)
            meetings.trash(withdrawnDraft.id)
            // Instrumentation.finish may terminate the process; cleanup must precede it.
            // Recover only our strictly named synthetic DRAFT fixtures from earlier runs.
            meetings.list().filter { it.status == MobileMeetingStatus.DRAFT &&
                it.title.matches(Regex("ReminderRegression [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}( withdrawn)?"))
            }.forEach { fixture ->
                val occurrence = "local:${fixture.id}"
                ReminderScheduler.cancel(targetContext, occurrence)
                notificationManager?.cancel(occurrence.hashCode())
                meetings.trash(fixture.id)
            }
        }
        finish(0, Bundle().apply {
            putString("result", "passed")
            putLong("plannedTriggerAtMs", beginsAt - ReminderPlanner.DEFAULT_ALERT_MINUTES * 60_000L)
            putString("postedOccurrence", postedEvent.occurrenceId)
            putString("suppressedOccurrence", withdrawnEvent.occurrenceId)
        })
    }

    /** Real microphone check, explicitly selected by instrumentation argument and bounded to five seconds. */
    private fun verifyMicNotificationStop() {
        check(BuildConfig.DEBUG) { "The mic test is allowed only in a debug/test variant" }
        check(targetContext.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "Mic test requires RECORD_AUDIO to be granted already; no permission prompt or grant was attempted."
        }
        check(NotificationManagerCompat.from(targetContext).areNotificationsEnabled()) {
            "Mic test requires notifications already enabled; no permission or setting was changed."
        }
        val power = targetContext.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        val keyguard = targetContext.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        check(power.isInteractive && !keyguard.isKeyguardLocked) { "Mic test requires the device to be awake and unlocked" }

        val meetings = MobileMeetingStore(targetContext)
        check(meetings.activeRecording() == null && !recordingServiceIsRunning()) {
            "Mic test will not start while another recording service/session is active"
        }
        val meeting = meetings.createDraft("MicStopRegression ${UUID.randomUUID()}")
        var started = false
        try {
            val launch = Intent(targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(MainActivity.EXTRA_PREVIEW, false)
            val activity = startActivitySync(launch)
            waitFor(2_000L) { activity.hasWindowFocus() } // Do not start capture while the test app is backgrounded.
            check(activity.hasWindowFocus()) { "MainActivity did not become the foreground activity" }

            check(MeetingRecordingService.start(activity, meeting.id)) { "Could not start the explicitly requested test recording" }
            started = true
            // The service enrolls explicit captures in phone-to-Mac transfer; this diagnostic clip stays local.
            check(targetContext.getSharedPreferences(MainActivity.TRANSFER_PREFS, Context.MODE_PRIVATE).edit()
                .remove("capture:${meeting.id}").commit()) { "Could not keep the diagnostic clip local" }
            val deadline = SystemClock.elapsedRealtime() + 5_500L
            var recordingNotification: Notification? = null
            while (SystemClock.elapsedRealtime() < deadline) {
                val current = meetings.find(meeting.id)
                recordingNotification = targetContext.getSystemService(NotificationManager::class.java)
                    ?.activeNotifications?.map { it.notification }
                    ?.firstOrNull { it.category == Notification.CATEGORY_SERVICE &&
                        it.extras?.getString(Notification.EXTRA_TITLE)?.contains("Grabando · ${meeting.title}") == true }
                if (current?.status == MobileMeetingStatus.RECORDING && recordingNotification != null) break
                Thread.sleep(100)
            }
            check(meetings.find(meeting.id)?.status == MobileMeetingStatus.RECORDING) { "Real microphone capture did not start" }
            val stop = recordingNotification?.actions?.firstOrNull { it.title?.toString() == "Terminar grabación" }?.actionIntent
            check(stop != null) { "Ongoing recording notification has no Stop PendingIntent" }
            Thread.sleep(1_000L) // Give MediaRecorder enough input to finalize a valid short clip.
            check(SystemClock.elapsedRealtime() - (meetings.find(meeting.id)?.recordingStartedElapsedMs ?: SystemClock.elapsedRealtime()) < 8_000L) {
                "Mic test exceeded its approximately eight-second capture bound before Stop"
            }
            stop.send()
            waitFor(2_000L) { meetings.find(meeting.id)?.status in setOf(MobileMeetingStatus.RECORDED, MobileMeetingStatus.INTERRUPTED) }
            val saved = meetings.find(meeting.id)
            val audio = File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/${meeting.id}.m4a")
            check(saved?.status == MobileMeetingStatus.RECORDED && audio.isFile && audio.length() > 0L) {
                "Notification Stop did not save the generated microphone audio: ${saved?.status} ${saved?.error.orEmpty()}"
            }
            waitFor(1_500L) { !recordingServiceIsRunning() }
            check(meetings.activeRecording() == null && !recordingServiceIsRunning()) { "Recording service stayed active after Stop" }
            started = false
            finish(0, Bundle().apply {
                putString("result", "passed")
                putString("meetingId", meeting.id)
                putLong("audioBytes", audio.length())
                putLong("savedDurationMs", saved.durationMs)
                putString("audioPath", audio.absolutePath)
                putString("captureBound", "approximately <= 8 seconds")
            })
        } finally {
            // If an assertion interrupts the run after startup, stop only this generated meeting; keep its audio/draft.
            if (started && meetings.activeRecording()?.id == meeting.id) {
                MeetingRecordingService.requestStop(targetContext, meeting.id, "mic-test-cleanup")
            }
        }
    }

    private fun activeNotification(id: Int): Notification? =
        targetContext.getSystemService(NotificationManager::class.java)?.activeNotifications
            ?.firstOrNull { it.id == id }?.notification

    private fun awaitNotification(id: Int, timeoutMs: Long): Notification? {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            activeNotification(id)?.let { return it }
            Thread.sleep(50)
        }
        return activeNotification(id)
    }

    private fun waitFor(timeoutMs: Long, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (!predicate() && SystemClock.elapsedRealtime() < deadline) Thread.sleep(50)
    }

    @Suppress("DEPRECATION")
    private fun recordingServiceIsRunning(): Boolean =
        (targetContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == MeetingRecordingService::class.java.name }

    /** Explicit opt-in physical check; no microphone, credentials, or audio. */
    private fun verifyScreenReminder() {
        val power = targetContext.getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
        val wasInteractive = power.isInteractive
        check(!wasInteractive) { "Physical wake test requires the display to start off" }
        val reminder = RecordingScreenReminder(targetContext, android.os.Handler(android.os.Looper.getMainLooper()), 5000L)
        try {
            runOnMainSync { reminder.start() }
            val deadline = android.os.SystemClock.elapsedRealtime() + 8000L
            while (!reminder.holdsWakeLock() && android.os.SystemClock.elapsedRealtime() < deadline) Thread.sleep(25)
            val heldDuringPulse = reminder.holdsWakeLock()
            check(heldDuringPulse) { "Wake-lock acquisition was not observed; wake behavior is inconclusive" }
            val woke = power.isInteractive
            check(woke) { "Android did not wake the display" }
            Thread.sleep(1200)
            val released = !reminder.holdsWakeLock()
            check(released) { "The one-second reminder wake lock did not expire" }
            runOnMainSync { reminder.stop() }
            finish(0, Bundle().apply {
                putString("result", "passed")
                putBoolean("interactiveBefore", wasInteractive)
                putBoolean("interactiveAfterPulse", woke)
                putBoolean("wakeLockHeldDuringPulse", heldDuringPulse)
                putBoolean("wakeLockTimedOut", released)
                putString("cadence", "Accelerated 5s physical pulse; production 5min cadence covered separately")
            })
        } finally {
            runOnMainSync { reminder.stop() }
        }
    }

    private fun verifyTransferSchedulingPermission() {
        check(targetContext.checkSelfPermission(android.Manifest.permission.ACCESS_NETWORK_STATE) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED) { "Network-constrained jobs require ACCESS_NETWORK_STATE" }
        val preferences = LocalStore(targetContext)
        val wasPreview = preferences.previewActive
        try {
            preferences.previewActive = true
            PhoneAudioTransferWorker.kick(targetContext)
        } finally {
            val scheduler = targetContext.getSystemService(android.content.Context.JOB_SCHEDULER_SERVICE) as android.app.job.JobScheduler
            scheduler.allPendingJobs.filter { it.service.className == PhoneAudioTransferJobService::class.java.name }
                .forEach { scheduler.cancel(it.id) }
            preferences.previewActive = wasPreview
        }
    }

    private fun verifyNormalFinalization() {
        val store = MobileMeetingStore(targetContext)
        val meeting = store.createDraft("StoreRegressionTest ${UUID.randomUUID()}")
        try {
            val partial = requireNotNull(store.claimRecording(meeting.id)) { "Could not claim normal test recording" }
            partial.writeBytes(TEST_AUDIO_BYTES)
            check(store.markRecordingStarted(meeting.id)) { "Could not mark normal test recording started" }
            check(store.completeRecording(meeting.id, partial, 1250L)) { "Normal recording finalization failed" }
            check(store.find(meeting.id)?.status == MobileMeetingStatus.RECORDED) { "Finalized meeting metadata was not recorded" }
            check(File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/${meeting.id}.m4a").isFile) { "Final audio file is missing" }
            check(!partial.exists()) { "Partial audio file remains after finalization" }
            check(store.playbackUri(meeting.id) != null) { "Finalized audio cannot be opened for playback" }
        } finally {
            cleanup(store, meeting.id)
        }
    }

    private fun verifyInterruptedFinalization() {
        val store = MobileMeetingStore(targetContext)
        val meeting = store.createDraft("StoreRegressionTest ${UUID.randomUUID()}")
        try {
            val partial = requireNotNull(store.claimRecording(meeting.id)) { "Could not claim interrupted test recording" }
            partial.writeBytes(TEST_AUDIO_BYTES)
            check(store.markRecordingStarted(meeting.id)) { "Could not mark interrupted test recording started" }
            check(store.finalizeInterruptedRecording(meeting.id, partial, "Test interruption", 750L)) { "Interrupted recording finalization failed" }
            check(store.find(meeting.id)?.status == MobileMeetingStatus.INTERRUPTED) { "Interrupted metadata was not saved" }
            check(File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/${meeting.id}.m4a").isFile) { "Interrupted final audio file is missing" }
            check(!partial.exists()) { "Partial audio file remains after interrupted finalization" }
            check(store.playbackUri(meeting.id) != null) { "Finalized interrupted audio cannot be opened for playback" }
        } finally {
            cleanup(store, meeting.id)
        }
    }

    private fun cleanup(store: MobileMeetingStore, id: String) {
        File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/$id.m4a").delete()
        File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/$id.m4a.partial").delete()
        store.trash(id)
    }

    private fun verifyTrashedDraftCannotRecord() {
        val store = MobileMeetingStore(targetContext)
        val meeting = store.createDraft("StoreRegressionTest trashed ${UUID.randomUUID()}")
        check(store.trash(meeting.id))
        check(store.claimRecording(meeting.id) == null) { "A stale click opened a trashed draft for capture" }
        check(store.find(meeting.id)?.status == MobileMeetingStatus.DRAFT)
    }

    private fun verifyHiddenOccurrenceRoundTrip() {
        val store = LocalStore(targetContext)
        val key = "StoreRegressionTest:${UUID.randomUUID()}"
        check(!store.occurrenceHidden(key))
        store.hideOccurrence(key, true)
        check(store.occurrenceHidden(key)) { "Hidden calendar occurrence was not persisted" }
        store.hideOccurrence(key, false)
        check(!store.occurrenceHidden(key)) { "Restored calendar occurrence remains hidden" }
    }

    companion object {
        private val TEST_AUDIO_BYTES = byteArrayOf(0x00, 0x10, 0x20, 0x30, 0x40)
    }
}
