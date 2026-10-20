package app.halle.companion

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** User-started, local-only microphone recording. This service never restores a recording on its own. */
class MeetingRecordingService : Service() {
    private var recorder: MediaRecorder? = null
    private var meetingId: String? = null
    private var partialFile: File? = null
    private var startedElapsedMs: Long = 0
    private var audioCallback: android.media.AudioManager.AudioRecordingCallback? = null
    private var leaseGuard: (() -> Boolean)? = null
    private var sharedLease: SharedRecordingLease? = null
    private var sharedLeaseClient: SharedSessionClient? = null
    private var sharedLeaseDeadline: LeaseDeadline? = null
    private var sharedLeaseRenewal: AutoCloseable? = null
    private val handler = Handler(Looper.getMainLooper())

    private val leasePoll = object : Runnable {
        override fun run() {
            if (meetingId == null) return
            val guard = leaseGuard
            if (sharedLease?.cancellationRequested?.get() == true) {
                finishRecording("Shared recording was cancelled; recording stopped.")
            } else if (guard != null && !runCatching(guard).getOrDefault(false)) {
                finishRecording("Shared-session permission expired; recording stopped.")
            } else handler.postDelayed(this, LEASE_POLL_MS)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                val requestedId = intent.getStringExtra(EXTRA_MEETING_ID)
                if (requestedId == null || meetingId == requestedId) {
                    val reason = intent.getStringExtra("stopReason")
                    finishRecording(when (reason) {
                        null, "user" -> null
                        "activity-backgrounded" -> "Hall-e left the foreground before recording startup was confirmed."
                        else -> "Android could not confirm recording startup."
                    })
                }
            }
            ACTION_START -> {
                val id = intent.getStringExtra(EXTRA_MEETING_ID)
                if (id == null || !startRecording(id)) stopSelf(startId)
            }
        }
        return START_NOT_STICKY
    }

    private fun startRecording(id: String): Boolean {
        if (recorder != null || meetingId != null) {
            pendingLeaseGuards.remove(id)
            pendingSharedLeases.remove(id)?.let(::finalizeUnstartedLease)
            return true // Ignore double taps and competing starts without stopping the active session.
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            pendingLeaseGuards.remove(id)
            pendingSharedLeases.remove(id)?.let(::finalizeUnstartedLease)
            return false
        }
        val store = MobileMeetingStore(this)
        store.recoverInterrupted()
        val suppliedGuard = pendingLeaseGuards.remove(id)
        val assignedLease = pendingSharedLeases.remove(id)
        if (suppliedGuard != null && !runCatching(suppliedGuard).getOrDefault(false)) {
            assignedLease?.let(::finalizeUnstartedLease)
            return false
        }
        if (assignedLease != null && SystemClock.elapsedRealtime() >= assignedLease.localDeadlineElapsedMs) {
            finalizeUnstartedLease(assignedLease)
            return false
        }
        val output = store.claimRecording(id) ?: run {
            pendingLeaseGuards.remove(id)
            assignedLease?.let(::finalizeUnstartedLease)
            return false
        }
        meetingId = id
        partialFile = output
        startedElapsedMs = SystemClock.elapsedRealtime()
        sharedLease = assignedLease
        leaseGuard = suppliedGuard
        if (assignedLease != null) {
            sharedLeaseClient = SharedSessionClient(this)
            sharedLeaseDeadline = LeaseDeadline(assignedLease.localDeadlineElapsedMs)
            leaseGuard = { sharedLeaseDeadline?.isValid() == true }
        }

        try {
            createNotificationChannel()
            startForeground(NOTIFICATION_ID, notification(store.find(id)?.title ?: "Meeting"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)

            val media = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(this) else MediaRecorder()
            recorder = media
            media.setAudioSource(MediaRecorder.AudioSource.MIC)
            media.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            media.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            media.setAudioEncodingBitRate(AUDIO_BIT_RATE)
            media.setAudioSamplingRate(AUDIO_SAMPLE_RATE)
            media.setOutputFile(output.absolutePath)
            media.prepare()
            if (assignedLease?.cancellationRequested?.get() == true ||
                (leaseGuard != null && !runCatching(leaseGuard!!).getOrDefault(false))) {
                releaseRecorder()
                val reason = if (assignedLease?.cancellationRequested?.get() == true)
                    "Shared recording was cancelled before capture began."
                else "Shared-session recording permission expired before capture began."
                store.returnUnstartedRecordingToDraft(id, output, reason)
                stopForeground(STOP_FOREGROUND_REMOVE)
                meetingId = null
                partialFile = null
                assignedLease?.let(::finalizeUnstartedLease)
                sharedLease = null
                sharedLeaseClient = null
                sharedLeaseDeadline = null
                sharedLeaseRenewal = null
                leaseGuard = null
                stopSelf()
                return false
            }
            // Recheck immediately before opening the microphone; an activity may have timed out
            // while MediaRecorder was being prepared.
            if (assignedLease?.cancellationRequested?.get() == true ||
                (leaseGuard != null && !runCatching(leaseGuard!!).getOrDefault(false))) {
                releaseRecorder()
                store.returnUnstartedRecordingToDraft(id, output, "Shared recording was cancelled before capture began.")
                stopForeground(STOP_FOREGROUND_REMOVE)
                meetingId = null
                partialFile = null
                assignedLease?.let(::finalizeUnstartedLease)
                sharedLease = null
                sharedLeaseClient = null
                sharedLeaseDeadline = null
                sharedLeaseRenewal = null
                leaseGuard = null
                stopSelf()
                return false
            }
            media.start()
            if (!store.markRecordingStarted(id)) {
                finishRecording("The recording could not be confirmed in local storage.")
                return false
            }
            registerSilenceMonitor(media)
            if (assignedLease != null) {
                sharedLeaseRenewal = sharedLeaseClient?.renewWhileRecording(
                    assignedLease, sharedLeaseDeadline!!,
                ) {
                    handler.post {
                        if (meetingId == id) finishRecording("Shared recording lease expired or handoff was requested; recording stopped.")
                    }
                }
            }
            if (leaseGuard != null) handler.postDelayed(leasePoll, LEASE_POLL_MS)
            return true
        } catch (failure: Exception) {
            releaseRecorder()
            store.failRecording(id, "Could not start microphone recording: ${failure.javaClass.simpleName}.")
            stopForeground(STOP_FOREGROUND_REMOVE)
            meetingId = null
            partialFile = null
            assignedLease?.let(::finalizeUnstartedLease)
            sharedLease = null
            sharedLeaseClient = null
            sharedLeaseDeadline = null
            sharedLeaseRenewal = null
            leaseGuard = null
            stopSelf()
            return false
        }
    }

    private fun registerSilenceMonitor(media: MediaRecorder) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val callback = object : android.media.AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<android.media.AudioRecordingConfiguration>?) {
                val current = media.activeRecordingConfiguration
                val oursSilenced = current != null && configs.orEmpty().any {
                    it.clientAudioSessionId == current.clientAudioSessionId && it.isClientSilenced
                }
                if (oursSilenced && meetingId != null) {
                    finishRecording("Android silenced the microphone while another audio session was active. The saved recording may be incomplete.")
                }
            }
        }
        audioCallback = callback
        media.registerAudioRecordingCallback(mainExecutor, callback)
    }

    private fun finishRecording(interruption: String?) {
        val id = meetingId ?: run { stopSelf(); return }
        val output = partialFile
        val elapsed = (SystemClock.elapsedRealtime() - startedElapsedMs).coerceAtLeast(0)
        handler.removeCallbacks(leasePoll)
        sharedLeaseRenewal?.close()
        sharedLeaseRenewal = null
        unregisterSilenceMonitor()
        val currentRecorder = recorder
        var finalized = false
        if (currentRecorder != null) {
            try {
                currentRecorder.stop()
                finalized = true
            } catch (_: RuntimeException) {
                // MediaRecorder intentionally fails stop() if too little valid input was captured.
            } finally {
                releaseRecorder()
            }
        }
        val store = MobileMeetingStore(this)
        val saved = if (output != null && finalized) {
            if (interruption == null) store.completeRecording(id, output, elapsed)
            else store.finalizeInterruptedRecording(id, output, interruption, elapsed)
        } else false
        if (!saved && (interruption != null || !finalized || output == null)) {
            store.interruptRecording(id, interruption ?: "Recording stopped before a complete audio file was created.", elapsed)
        } else if (!saved) {
            store.interruptRecording(id, "The audio file could not be finalized. The saved file may be incomplete.", elapsed)
        }
        sharedLease?.let { lease ->
            val client = sharedLeaseClient
            if (client != null) sharedLeaseExecutor.execute {
                runCatching {
                    client.finalizeSegmentAndRelease(lease, if (saved && interruption == null) "complete" else "interrupted")
                }
            }
        }
        meetingId = null
        partialFile = null
        sharedLease = null
        sharedLeaseClient = null
        sharedLeaseDeadline = null
        leaseGuard = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun releaseRecorder() {
        runCatching { recorder?.reset() }
        runCatching { recorder?.release() }
        recorder = null
    }

    private fun unregisterSilenceMonitor() {
        val callback = audioCallback ?: return
        runCatching { recorder?.unregisterAudioRecordingCallback(callback) }
        audioCallback = null
    }

    private fun finalizeUnstartedLease(lease: SharedRecordingLease) {
        val client = SharedSessionClient(this)
        sharedLeaseExecutor.execute { runCatching { client.finalizeSegmentAndRelease(lease, "interrupted") } }
    }

    private fun notification(title: String): Notification {
        val stopIntent = Intent(this, MeetingRecordingService::class.java).setAction(ACTION_STOP)
            .putExtra(EXTRA_MEETING_ID, meetingId)
        val stopAction = PendingIntent.getService(this, NOTIFICATION_ID, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Recording · $title")
            .setContentText("Tap Stop to finish and save this recording on this phone.")
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopAction)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Meeting recording", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "Shows when Hall-e is recording audio on this device." },
            )
        }
    }

    override fun onDestroy() {
        if (meetingId != null) {
            finishRecording("Android stopped the recording service. The saved audio may be incomplete.")
        } else {
            handler.removeCallbacks(leasePoll)
            unregisterSilenceMonitor()
            releaseRecorder()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val ACTION_START = "app.halle.companion.action.START_RECORDING"
        private const val ACTION_STOP = "app.halle.companion.action.STOP_RECORDING"
        private const val EXTRA_MEETING_ID = "meetingId"
        private const val CHANNEL_ID = "meeting-recording"
        private const val NOTIFICATION_ID = 0x4842
        private const val AUDIO_BIT_RATE = 128_000
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val LEASE_POLL_MS = 2_000L
        private val pendingLeaseGuards = ConcurrentHashMap<String, () -> Boolean>()
        private val pendingSharedLeases = ConcurrentHashMap<String, SharedRecordingLease>()
        private val sharedLeaseExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "halle-shared-finalize").apply { isDaemon = true }
        }

        /** Call only from a visible activity after RECORD_AUDIO is granted. */
        fun start(
            context: Context,
            meetingId: String,
            leaseGuard: (() -> Boolean)? = null,
            sharedLease: SharedRecordingLease? = null,
        ): Boolean {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) return false
            val store = MobileMeetingStore(context)
            store.recoverInterrupted()
            val draft = store.find(meetingId) ?: return false
            if (draft.status != MobileMeetingStatus.DRAFT) return false
            if (leaseGuard != null) pendingLeaseGuards[meetingId] = leaseGuard
            if (sharedLease != null) pendingSharedLeases[meetingId] = sharedLease
            val intent = Intent(context, MeetingRecordingService::class.java)
                .setAction(ACTION_START).putExtra(EXTRA_MEETING_ID, meetingId)
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (_: Exception) {
                pendingLeaseGuards.remove(meetingId)
                pendingSharedLeases.remove(meetingId)
                false
            }
        }

        /** Call for an explicit user stop; the ongoing notification has the same action. */
        fun stop(context: Context) {
            val id = MobileMeetingStore(context).activeRecording()?.id ?: return
            requestStop(context, id, "user")
        }

        /** Stop only the named meeting so a stale timeout cannot stop a later recording. */
        fun requestStop(context: Context, meetingId: String, reason: String) {
            runCatching {
                context.startService(Intent(context, MeetingRecordingService::class.java)
                    .setAction(ACTION_STOP).putExtra(EXTRA_MEETING_ID, meetingId).putExtra("stopReason", reason))
            }
        }
    }
}
