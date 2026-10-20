package app.halle.companion

import android.app.job.JobParameters
import android.app.job.JobService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/** OS-persisted network retry lane for stopped phone recordings. */
class PhoneAudioTransferJobService : JobService() {
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "halle-phone-audio-job") }
    private val generations = AtomicLong(0)

    companion object {
        private val lock = Any()
        @Volatile private var running = false
        private var rerunRequested = false
        private var rerunPrioritized = false
        fun isRunning(): Boolean = running
        fun requestAnotherRunIfRunning(prioritizeNow: Boolean): Boolean = synchronized(lock) {
            if (!running) return@synchronized false
            rerunRequested = true
            rerunPrioritized = rerunPrioritized || prioritizeNow
            true
        }
    }

    override fun onStartJob(params: JobParameters): Boolean {
        val started = synchronized(lock) {
            if (running) {
                rerunRequested = true
                false
            } else {
                running = true
                true
            }
        }
        if (!started) return false
        val generation = generations.incrementAndGet()
        executor.execute {
            val retry = runCatching {
                PhoneAudioTransferWorker.perform(applicationContext) { generations.get() == generation }
            }.getOrDefault(false).not()
            val (rerun, prioritizeRerun) = synchronized(lock) {
                running = false
                val requested = rerunRequested
                val prioritized = rerunPrioritized
                rerunRequested = false
                rerunPrioritized = false
                if (generations.get() == generation) jobFinished(params, retry)
                requested to prioritized
            }
            if (rerun) PhoneAudioTransferWorker.kick(applicationContext, prioritizeNow = prioritizeRerun)
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        generations.incrementAndGet()
        return true
    }

    override fun onDestroy() {
        generations.incrementAndGet()
        // Drain even a cancelled queued task so it releases the static single-flight flag.
        executor.shutdown()
        super.onDestroy()
    }
}
