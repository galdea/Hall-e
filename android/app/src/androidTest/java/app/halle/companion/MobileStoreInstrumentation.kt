package app.halle.companion

import android.app.Instrumentation
import android.os.Bundle
import java.io.File
import java.util.UUID

/** Device-side regression for the partial-to-final rename and metadata commit boundary. */
class MobileStoreInstrumentation : Instrumentation() {
    private var reminderOnly = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        reminderOnly = arguments?.getString("screen-reminder") == "true"
        start()
    }

    override fun onStart() {
        try {
            if (reminderOnly) { verifyScreenReminder(); return }
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
