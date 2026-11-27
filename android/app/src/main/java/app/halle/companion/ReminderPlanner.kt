package app.halle.companion

import java.time.LocalDate
import java.time.ZoneId
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

object ReminderPlanner {
    const val DEFAULT_ALERT_MINUTES = 10

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

    /** Future local drafts get reminders unless they came from a calendar event. */
    fun localScheduledDrafts(meetings: List<MobileMeeting>): List<MeetingOccurrence> = meetings.mapNotNull { meeting ->
        val begin = meeting.scheduledStartAtMs ?: return@mapNotNull null
        val end = meeting.scheduledEndAtMs ?: return@mapNotNull null
        if (meeting.status != MobileMeetingStatus.DRAFT || meeting.trashedAtMs != null ||
            meeting.sourceEventKey != null || begin <= 0 || end <= begin) return@mapNotNull null
        MeetingOccurrence(
            calendarId = Long.MIN_VALUE,
            eventId = meeting.id.hashCode().toLong(),
            beginMillis = begin,
            endMillis = end,
            title = meeting.title,
            location = null,
            allDay = false,
            canceled = false,
            declined = false,
            meetingUrl = null,
            calendarName = "This device",
            reminderKey = "local:${meeting.id}",
            localMeetingId = meeting.id,
        )
    }

    fun excludeCalendarDuplicates(
        localEvents: List<MeetingOccurrence>,
        calendarEvents: List<MeetingOccurrence>,
    ): List<MeetingOccurrence> {
        val calendarKeys = calendarEvents.map { it.occurrenceId }.toSet()
        val calendarSignatures = calendarEvents.map { event ->
            Triple(event.beginMillis, event.endMillis, event.title.trim().lowercase(Locale.ROOT))
        }.toSet()
        return localEvents.filterNot { local ->
            local.localMeetingId == null || local.localMeetingId in calendarKeys ||
                Triple(local.beginMillis, local.endMillis, local.title.trim().lowercase(Locale.ROOT)) in calendarSignatures
        }
    }

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

    /** Órbita (Spanish) wording of [summary], with 24-hour times. */
    fun summaryEs(events: List<MeetingOccurrence>, nowMillis: Long, zone: ZoneId = ZoneId.systemDefault()): String = when {
        events.isEmpty() -> "Tu agenda de hoy está despejada. Guarda un poco de espacio para ti."
        else -> {
            val next = events.firstOrNull { it.endMillis > nowMillis }
            val count = events.size
            val meetings = if (count == 1) "1 reunión" else "$count reuniones"
            if (next == null) "Hoy tienes $meetings. Ya terminaste por hoy."
            else {
                val at = if (next.allDay) "durante todo el día"
                    else "a las " + DateTimeFormatter.ofPattern("HH:mm").format(Instant.ofEpochMilli(next.beginMillis).atZone(zone))
                "Hoy tienes $meetings. Próxima: ${next.title} $at."
            }
        }
    }
}
