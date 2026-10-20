package app.halle.companion

import java.time.LocalDate
import java.time.ZoneId
import java.time.Instant
import java.time.ZoneOffset

object ReminderPlanner {
    fun alertAt(event: MeetingOccurrence, minutesBefore: Int): Long? {
        if (event.canceled || event.declined || event.allDay || event.endMillis <= 0) return null
        if (minutesBefore !in 0..1440) return null
        return event.beginMillis - minutesBefore * 60_000L
    }

    fun eligible(events: List<MeetingOccurrence>, minutesBefore: Int, nowMillis: Long,
                 deliveredOccurrenceIds: Set<String> = emptySet()): List<Pair<MeetingOccurrence, Long>> =
        events.mapNotNull { event ->
            val alertAt = alertAt(event, minutesBefore) ?: return@mapNotNull null
            val fireAt = when {
                alertAt > nowMillis -> alertAt
                event.beginMillis > nowMillis -> nowMillis + 1_000L // Missed lead time, meeting is still upcoming.
                event.endMillis > nowMillis && nowMillis - event.beginMillis <= 10 * 60_000L -> nowMillis + 1_000L
                else -> return@mapNotNull null
            }
            event to fireAt
        }
            .filterNot { (event, _) -> event.occurrenceId in deliveredOccurrenceIds }
            .distinctBy { it.first.occurrenceId }
            .sortedBy { it.second }

    fun shouldDeliver(event: MeetingOccurrence?, expectedOccurrenceId: String, nowMillis: Long): Boolean =
        event != null && event.occurrenceId == expectedOccurrenceId && !event.canceled && !event.declined
            && !event.allDay && event.endMillis > nowMillis

    fun snoozeAt(nowMillis: Long, endMillis: Long, snoozeMinutes: Int = 5): Long? {
        val candidate = nowMillis + snoozeMinutes * 60_000L
        val latest = endMillis - 60_000L
        return candidate.takeIf { snoozeMinutes > 0 && endMillis > nowMillis && it <= latest }
    }

    fun forLocalDate(events: List<MeetingOccurrence>, date: LocalDate,
                     zone: ZoneId = ZoneId.systemDefault()): List<MeetingOccurrence> {
        val dayStart = date.atStartOfDay(zone).toInstant().toEpochMilli()
        val nextDayStart = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        return events.filter { event ->
            if (event.allDay) Instant.ofEpochMilli(event.beginMillis).atZone(ZoneOffset.UTC).toLocalDate() == date
            else event.beginMillis < nextDayStart && event.endMillis > dayStart
        }
            .sortedWith(compareBy<MeetingOccurrence> { it.allDay.not() }.thenBy { it.beginMillis })
    }

    fun summary(events: List<MeetingOccurrence>, nowMillis: Long): String = when {
        events.isEmpty() -> "Your calendar is clear today. Keep a little space for yourself."
        else -> {
            val next = events.firstOrNull { it.endMillis > nowMillis }
            val count = events.size
            if (next == null) "You have $count meeting${if (count == 1) "" else "s"} today. You’re all caught up."
            else "You have $count meeting${if (count == 1) "" else "s"} today. Next: ${next.title} at ${next.startsAt()}."
        }
    }
}
