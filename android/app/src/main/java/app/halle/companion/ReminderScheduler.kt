package app.halle.companion

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build

object ReminderScheduler {
    fun refresh(context: Context) {
        val store = LocalStore(context)
        val repository = CalendarRepository(context, store)
        if (!repository.hasPermission()) {
            store.scheduledOccurrenceIds.forEach { cancel(context, it) }
            store.scheduledOccurrenceIds = emptySet()
            return
        }
        val now = System.currentTimeMillis()
        val events = repository.events(now, now + 30L * 24 * 60 * 60 * 1000)
        val planned = ReminderPlanner.eligible(events, store.alertMinutes, now, store.deliveredOccurrenceIds)
        val nextIds = planned.map { it.first.occurrenceId }.toSet()
        (store.scheduledOccurrenceIds - nextIds).forEach { cancel(context, it) }
        planned.forEach { (event, fireAt) -> schedule(context, event, fireAt) }
        store.scheduledOccurrenceIds = nextIds
    }

    fun schedule(context: Context, event: MeetingOccurrence, fireAtMillis: Long) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = pendingIntent(context, event, 0)
        if (Build.VERSION.SDK_INT >= 31 && manager.canScheduleExactAlarms()) {
            manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAtMillis, pending)
        } else {
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAtMillis, pending)
        }
    }

    fun cancel(context: Context, occurrenceId: String) {
        val intent = Intent(context, MeetingAlertReceiver::class.java)
            .setData(Uri.parse("halle://meeting/${Uri.encode(occurrenceId)}"))
        PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            ?.let { pending ->
                context.getSystemService(AlarmManager::class.java)?.cancel(pending)
                pending.cancel()
            }
    }

    fun pendingIntent(context: Context, event: MeetingOccurrence, flags: Int): PendingIntent =
        PendingIntent.getBroadcast(context, 0, Intent(context, MeetingAlertReceiver::class.java)
            .setData(Uri.parse("halle://meeting/${Uri.encode(event.occurrenceId)}"))
            .putExtra(MeetingAlertReceiver.EXTRA_OCCURRENCE, event.occurrenceId)
            .putExtra(MeetingAlertReceiver.EXTRA_EVENT, event.eventId)
            .putExtra(MeetingAlertReceiver.EXTRA_CALENDAR, event.calendarId)
            .putExtra(MeetingAlertReceiver.EXTRA_BEGIN, event.beginMillis)
            .putExtra(MeetingAlertReceiver.EXTRA_END, event.endMillis)
            .putExtra(MeetingAlertReceiver.EXTRA_TITLE, event.title)
            .putExtra(MeetingAlertReceiver.EXTRA_URL, event.meetingUrl),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE or flags)

    fun snooze(context: Context, intent: Intent): Boolean {
        val begin = intent.getLongExtra(MeetingAlertReceiver.EXTRA_BEGIN, 0)
        val occurrence = intent.getStringExtra(MeetingAlertReceiver.EXTRA_OCCURRENCE) ?: return false
        val repository = CalendarRepository(context, LocalStore(context))
        if (!repository.hasPermission()) return false
        val end = intent.getLongExtra(MeetingAlertReceiver.EXTRA_END, 0)
        val now = System.currentTimeMillis()
        val current = repository.events(begin, maxOf(end, now + 1L)).firstOrNull { it.occurrenceId == occurrence }
        if (!ReminderPlanner.shouldDeliver(current, occurrence, now)) return false
        val meeting = current ?: return false
        val fireAt = ReminderPlanner.snoozeAt(now, meeting.endMillis) ?: return false
        scheduleSnooze(context, meeting, fireAt)
        return true
    }

    private fun scheduleSnooze(context: Context, event: MeetingOccurrence, fireAtMillis: Long) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = PendingIntent.getBroadcast(context, 0, Intent(context, MeetingAlertReceiver::class.java)
            .setData(Uri.parse("halle://snooze-alarm/${Uri.encode(event.occurrenceId)}"))
            .putExtra(MeetingAlertReceiver.EXTRA_OCCURRENCE, event.occurrenceId)
            .putExtra(MeetingAlertReceiver.EXTRA_EVENT, event.eventId)
            .putExtra(MeetingAlertReceiver.EXTRA_CALENDAR, event.calendarId)
            .putExtra(MeetingAlertReceiver.EXTRA_BEGIN, event.beginMillis)
            .putExtra(MeetingAlertReceiver.EXTRA_END, event.endMillis)
            .putExtra(MeetingAlertReceiver.EXTRA_TITLE, event.title)
            .putExtra(MeetingAlertReceiver.EXTRA_URL, event.meetingUrl)
            .putExtra(MeetingAlertReceiver.EXTRA_SNOOZE, true)
            .putExtra(MeetingAlertReceiver.EXTRA_SNOOZE_FIRE_AT, fireAtMillis),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        if (Build.VERSION.SDK_INT >= 31 && manager.canScheduleExactAlarms()) {
            manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAtMillis, pending)
        } else {
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, fireAtMillis, pending)
        }
    }
}
