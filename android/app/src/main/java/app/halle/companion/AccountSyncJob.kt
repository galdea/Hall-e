package app.halle.companion

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import org.json.JSONObject
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
                    val calendar = AccountCalendar(context, session)
                    val request = live(sessions, session)
                    calendar.sync(request)
                    // Capabilities only decide which actions are offered; failing to read them never fails a sync.
                    try { calendar.refreshFeatures(request) } catch (error: Exception) {
                        if (error is AccountHttpError && error.status == 401) throw error
                    }
                } catch (error: AccountHttpError) {
                    if (error.status == 401) sessions.logout(session, false)
                    throw error
                }
            }
            done(if (session == null) revocationError else null)
        } catch (error: Exception) { done(error) }
    }

    /**
     * Runs on the sync thread so no pull can rewrite the wiped calendar afterwards. On 202 the account's local cache
     * and stored session are removed without queuing a logout revocation; the service already revoked every session.
     */
    fun deleteAccount(context: Context, session: AccountSession, done: (Exception?) -> Unit): Future<*> = executor.submit {
        val sessions = AccountSessions(context)
        try {
            try {
                AccountCalendar(context, session).deleteAccount(live(sessions, session),
                    keepRecordings = { AccountRecordingMoves.add(context, session.scope) }) { sessions.logout(session, false) }
            } catch (error: AccountHttpError) {
                if (error.status == 401) sessions.logout(session, false)
                throw error
            }
            done(null)
        } catch (error: Exception) { done(error) }
        // A recording still in progress is moved when its recorder stops (MeetingRecordingService).
        AccountRecordingMoves.resumeAsync(context)
    }

    private fun live(sessions: AccountSessions, session: AccountSession): (String, String, JSONObject?, ByteArray?) -> JSONObject =
        { path, method, body, bytes ->
            if (Thread.currentThread().isInterrupted || sessions.current()?.token != session.token) throw IOException("Session changed")
            AccountTransport.request(session.origin, path, method, session.token, body, bytes)
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
