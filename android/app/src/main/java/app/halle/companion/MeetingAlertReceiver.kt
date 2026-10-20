package app.halle.companion

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

class MeetingAlertReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val begin = intent.getLongExtra(EXTRA_BEGIN, 0)
        val end = intent.getLongExtra(EXTRA_END, 0)
        val occurrence = intent.getStringExtra(EXTRA_OCCURRENCE) ?: return
        val now = System.currentTimeMillis()
        val store = LocalStore(context)
        if (BuildConfig.DEBUG && store.previewActive) return
        val repository = CalendarRepository(context, store)
        if (!repository.hasPermission()) return
        val current = repository.events(begin, maxOf(end, now + 1L)).firstOrNull { it.occurrenceId == occurrence }
        if (!ReminderPlanner.shouldDeliver(current, occurrence, now)) return
        val meeting = current ?: return
        val isSnooze = intent.getBooleanExtra(EXTRA_SNOOZE, false)
        val deliveryKey = if (isSnooze) "$occurrence#snooze#${intent.getLongExtra(EXTRA_SNOOZE_FIRE_AT, 0)}" else occurrence
        createChannel(context)
        val notificationManager = NotificationManagerCompat.from(context)
        if (!notificationManager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = context.getSystemService(NotificationManager::class.java)?.getNotificationChannel(CHANNEL_ID)
            if (channel == null || channel.importance == NotificationManager.IMPORTANCE_NONE) return
        }
        if (!store.claimDelivery(deliveryKey)) return
        val freshIntent = Intent(intent)
            .putExtra(EXTRA_EVENT, meeting.eventId)
            .putExtra(EXTRA_CALENDAR, meeting.calendarId)
            .putExtra(EXTRA_BEGIN, meeting.beginMillis)
            .putExtra(EXTRA_END, meeting.endMillis)
            .putExtra(EXTRA_TITLE, meeting.title)
            .putExtra(EXTRA_URL, meeting.meetingUrl)
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse("halle://open/${intent.getStringExtra(EXTRA_OCCURRENCE)}"))
            .putExtras(freshIntent), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Coming up · ${meeting.title}")
            .setContentText("Your calendar reminder is ready.")
            .setStyle(NotificationCompat.BigTextStyle().bigText(meeting.title))
            .setContentIntent(open).setAutoCancel(true).setPriority(NotificationCompat.PRIORITY_HIGH)
        val snooze = PendingIntent.getBroadcast(context, 0, Intent(context, SnoozeReceiver::class.java)
            .setData(Uri.parse("halle://snooze/${Uri.encode(intent.getStringExtra(EXTRA_OCCURRENCE).orEmpty())}"))
            .putExtras(freshIntent), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        builder.addAction(android.R.drawable.ic_media_pause, "Snooze 5 min", snooze)
        meeting.meetingUrl?.let { url ->
            val join = PendingIntent.getActivity(context, 1, Intent(Intent.ACTION_VIEW, Uri.parse(url)),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(android.R.drawable.ic_menu_view, "Join", join)
        }
        try {
            notificationManager.notify(occurrence.hashCode(), builder.build())
            if (!isSnooze) store.deliveredOccurrenceIds = store.deliveredOccurrenceIds + occurrence
        } catch (_: SecurityException) {
            store.releaseDelivery(deliveryKey) // Permission may have been revoked after the alarm was scheduled.
        }
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) context.getSystemService(NotificationManager::class.java)
            ?.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Meeting reminders", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "Local reminders for selected calendar meetings" })
    }

    companion object {
        const val CHANNEL_ID = "meeting-reminders"
        const val EXTRA_OCCURRENCE = "occurrenceId"
        const val EXTRA_EVENT = "eventId"
        const val EXTRA_CALENDAR = "calendarId"
        const val EXTRA_BEGIN = "beginMillis"
        const val EXTRA_END = "endMillis"
        const val EXTRA_TITLE = "title"
        const val EXTRA_URL = "meetingUrl"
        const val EXTRA_SNOOZE = "snoozeDelivery"
        const val EXTRA_SNOOZE_FIRE_AT = "snoozeFireAt"
    }
}

class SnoozeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (ReminderScheduler.snooze(context, intent)) {
            val id = intent.getStringExtra(MeetingAlertReceiver.EXTRA_OCCURRENCE).orEmpty()
            NotificationManagerCompat.from(context).cancel(id.hashCode())
        }
    }
}

class CalendarRefreshReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ReminderScheduler.refresh(context)
    }
}
