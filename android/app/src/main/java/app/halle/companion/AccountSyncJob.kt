package app.halle.companion

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import java.io.IOException
import java.util.IdentityHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future

internal object AccountSync {
    private val executor = Executors.newSingleThreadExecutor()
    fun run(context: Context, done: (Exception?) -> Unit): Future<*> = executor.submit {
        val sessions = AccountSessions(context)
        try {
            val revocationError = runCatching { sessions.revokePending() }.exceptionOrNull() as? Exception
            val session = sessions.current()
            if (session != null) {
                try {
                    AccountCalendar(context, session).sync { path, method, body, bytes ->
                        if (Thread.currentThread().isInterrupted || sessions.current()?.token != session.token) throw IOException("Session changed")
                        AccountTransport.request(session.origin, path, method, session.token, body, bytes)
                    }
                } catch (error: AccountHttpError) {
                    if (error.status == 401) sessions.logout(session, false)
                    throw error
                }
            }
            done(if (session == null) revocationError else null)
        } catch (error: Exception) { done(error) }
    }
}

class AccountSyncJob : JobService() {
    private val running = IdentityHashMap<JobParameters, Future<*>>()
    override fun onStartJob(params: JobParameters): Boolean {
        // A one-shot upload and the periodic pull can overlap. A stopped run must never finish its replacement.
        running[params] = AccountSync.run(applicationContext) { error ->
            mainExecutor.execute {
                if (running.remove(params) != null) {
                    if (AccountSessions(this).current() == null) periodic(this, false)
                    jobFinished(params, error != null && (error !is AccountHttpError || error.status != 401))
                }
            }
        }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean { running.remove(params)?.cancel(true); return true }
    companion object {
        private const val UPLOAD = 0x484143
        private const val PERIODIC = 0x484144
        private fun builder(context: Context, id: Int) = JobInfo.Builder(id, ComponentName(context, AccountSyncJob::class.java))
            .setPersisted(true).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (scheduler.getPendingJob(UPLOAD) == null) scheduler.schedule(builder(context, UPLOAD)
                .setBackoffCriteria(30000L, JobInfo.BACKOFF_POLICY_EXPONENTIAL).build())
        }
        fun periodic(context: Context, enabled: Boolean) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (!enabled) scheduler.cancel(PERIODIC)
            else if (scheduler.getPendingJob(PERIODIC) == null) scheduler.schedule(builder(context, PERIODIC)
                .setPeriodic(15 * 60 * 1000L).build())
        }
    }
}
