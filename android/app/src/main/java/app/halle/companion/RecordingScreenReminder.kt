package app.halle.companion

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.PowerManager
import android.os.SystemClock

/** A monotonic, service-owned cadence for best-effort screen reminders. */
internal class RecordingReminderCadence(
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val nowMs: () -> Long,
    private val pulse: () -> Unit,
    private val intervalMs: Long = INTERVAL_MS,
) {
    init { require(intervalMs > 0) }

    private var active = false
    private var nextAtMs = 0L
    private val callback = Runnable { tick() }

    fun start() {
        stop()
        active = true
        nextAtMs = nowMs() + intervalMs
        scheduleNext()
    }

    fun stop() {
        active = false
        cancel(callback)
    }

    private fun tick() {
        if (!active) return
        val now = nowMs()
        if (now < nextAtMs) {
            schedule(callback, nextAtMs - now)
            return
        }
        pulse()
        do { nextAtMs += intervalMs } while (nextAtMs <= nowMs())
        scheduleNext()
    }

    private fun scheduleNext() {
        if (active) schedule(callback, (nextAtMs - nowMs()).coerceAtLeast(1L))
    }

    companion object { const val INTERVAL_MS = 5 * 60_000L }
}

/** Holds the screen wake lock for at most one second; display timing is best-effort. */
internal class RecordingScreenReminder(
    context: Context,
    handler: Handler,
    intervalMs: Long = RecordingReminderCadence.INTERVAL_MS,
) {
    private val appContext = context.applicationContext
    private val power = context.applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
    @Suppress("DEPRECATION")
    private val screenWakeLock = power?.newWakeLock(
        PowerManager.SCREEN_DIM_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
        "app.halle:recording-reminder",
    )?.apply { setReferenceCounted(false) }
    private val cadence = RecordingReminderCadence(
        schedule = { runnable, delay -> handler.postDelayed(runnable, delay) },
        cancel = handler::removeCallbacks,
        nowMs = SystemClock::elapsedRealtime,
        pulse = ::pulse,
        intervalMs = intervalMs,
    )

    internal fun holdsWakeLock(): Boolean = screenWakeLock?.isHeld == true

    fun start() = cadence.start()

    fun stop() {
        cadence.stop()
        runCatching { screenWakeLock?.takeIf { it.isHeld }?.release() }
    }

    @Suppress("DEPRECATION")
    private fun pulse() {
        runCatching { appContext.sendBroadcast(Intent(ACTION_REMINDER).setPackage(appContext.packageName)) }
        val manager = power ?: return
        if (manager.isInteractive) return
        // Timeout is a backstop if service teardown does not run promptly.
        runCatching { screenWakeLock?.acquire(PULSE_DURATION_MS) }
    }

    companion object {
        const val ACTION_REMINDER = "app.halle.companion.action.RECORDING_REMINDER"
        const val PULSE_DURATION_MS = 1_000L
    }
}
