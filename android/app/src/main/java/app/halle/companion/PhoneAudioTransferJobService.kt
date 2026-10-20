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
        fun isRunning(): Boolean = running
        fun requestAnotherRun() = synchronized(lock) { rerunRequested = true }
    }

    override fun onStartJob(params: JobParameters): Boolean {
        synchronized(lock) {
            if (running) return false
            running = true
        }
        val generation = generations.incrementAndGet()
        executor.execute {
            val retry = runCatching {
                PhoneAudioTransferWorker.perform(applicationContext) { generations.get() == generation }
            }.getOrDefault(false).not()
            val rerun = synchronized(lock) {
                running = false
                if (generations.get() == generation) jobFinished(params, retry)
                rerunRequested.also { rerunRequested = false }
            }
            if (rerun) PhoneAudioTransferWorker.kick(applicationContext)
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
