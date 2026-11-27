package app.halle.companion

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import org.junit.Assert.*
import org.junit.Test

class ReminderPlannerTest {
    private fun event(id: Long, begin: Long, end: Long = begin + 3_600_000, allDay: Boolean = false) =
        MeetingOccurrence(1, id, begin, end, "Meeting $id", null, allDay, false, false, null, "Work")

    @Test fun alertSkipsCanceledDeclinedAllDayAndPastOccurrences() {
        val now = 1_000_000L
        val valid = event(1, now + 600_000)
        val bad = listOf(
            valid.copy(eventId = 2, canceled = true), valid.copy(eventId = 3, declined = true),
            valid.copy(eventId = 4, allDay = true), event(5, now - 10 * 60_000L - 1),
        )
        assertEquals(listOf(valid.occurrenceId), ReminderPlanner.eligible(listOf(valid) + bad, 5, now).map { it.first.occurrenceId })
    }

    @Test fun alertTimeUsesConfiguredMinutesAndOccurrenceIdentity() {
        val meeting = event(9, 3_600_000)
        assertEquals(3_300_000L, ReminderPlanner.alertAt(meeting, 5))
        assertEquals("1:9:3600000", meeting.occurrenceId)
        assertNull(ReminderPlanner.alertAt(meeting, -1))
    }

    @Test fun snoozeMustFireBeforeMeetingEnds() {
        assertEquals(1_300_000L, ReminderPlanner.snoozeAt(1_000_000, 2_000_000))
        assertNull(ReminderPlanner.snoozeAt(1_000_000, 1_200_000))
    }

    @Test fun refreshDoesNotRescheduleAnOccurrenceAlreadyDelivered() {
        val now = 1_000_000L
        val first = event(1, now + 600_000)
        val second = event(2, now + 900_000)
        assertEquals(listOf(second.occurrenceId), ReminderPlanner.eligible(
            listOf(first, second), 5, now, setOf(first.occurrenceId)).map { it.first.occurrenceId })
    }

    @Test fun refreshCatchesUpMissedLeadTimeAndVeryRecentStartsOnly() {
        val now = 1_000_000L
        val upcoming = event(1, now + 2 * 60_000L)
        val recent = event(2, now - 5 * 60_000L, now + 30 * 60_000L)
        val stale = event(3, now - 10 * 60_000L - 1, now + 30 * 60_000L)
        val ended = event(4, now - 20 * 60_000L, now)
        assertEquals(listOf(upcoming.occurrenceId, recent.occurrenceId),
            ReminderPlanner.eligible(listOf(upcoming, recent, stale, ended), 5, now).map { it.first.occurrenceId })
        assertEquals(listOf(now + 1_000L, now + 1_000L),
            ReminderPlanner.eligible(listOf(upcoming, recent), 5, now).map { it.second })
    }

    @Test fun deliveryRequiresTheCurrentSelectedOccurrenceToRemainActive() {
        val meeting = event(7, 1_000_000, 2_000_000)
        assertTrue(ReminderPlanner.shouldDeliver(meeting, meeting.occurrenceId, 1_500_000))
        assertFalse(ReminderPlanner.shouldDeliver(meeting.copy(canceled = true), meeting.occurrenceId, 1_500_000))
        assertFalse(ReminderPlanner.shouldDeliver(meeting.copy(declined = true), meeting.occurrenceId, 1_500_000))
        assertFalse(ReminderPlanner.shouldDeliver(meeting.copy(allDay = true), meeting.occurrenceId, 1_500_000))
        assertFalse(ReminderPlanner.shouldDeliver(meeting.copy(beginMillis = 1_100_000), meeting.occurrenceId, 1_500_000))
        assertFalse(ReminderPlanner.shouldDeliver(null, meeting.occurrenceId, 1_500_000))
        assertFalse(ReminderPlanner.shouldDeliver(meeting, meeting.occurrenceId, 2_000_000))
    }

    @Test fun localDayFilteringHonorsZoneAndOrdersAllDayFirst() {
        val zone = ZoneId.of("America/Santiago")
        val date = LocalDate.of(2026, 10, 20)
        val start = date.atStartOfDay(zone).toInstant().toEpochMilli()
        val utcAllDayStart = date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
        val overnight = event(4, start - 3_600_000, start + 3_600_000)
        val items = listOf(event(1, start + 3_600_000), event(2, utcAllDayStart, allDay = true),
            event(3, start - 1), overnight)
        // event 3 starts one millisecond before local midnight, which is still
        // October 20 in Santiago and must be included. The all-day event itself
        // is keyed to its October 20 UTC date by CalendarContract.
        assertEquals(listOf(2L, 4L, 3L, 1L), ReminderPlanner.forLocalDate(items, date, zone).map { it.eventId })
        val tomorrow = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        assertTrue(ReminderPlanner.forLocalDate(listOf(event(4, tomorrow)), date, zone).isEmpty())
    }

    @Test fun localFutureScheduledDraftsAreIncludedWithoutDuplicatingCalendarDrafts() {
        val begin = 3_600_000L
        val base = MobileMeeting(
            id = "local-draft-id", title = "Local review", projectName = null, createdAtMs = 1,
            scheduledStartAtMs = begin, scheduledEndAtMs = begin + 3_600_000L,
            sourceEventKey = null, sharedSessionId = null, status = MobileMeetingStatus.DRAFT,
            audioFileName = null, recordingStartedAtMs = null, recordingStartedElapsedMs = null,
            durationMs = 0, error = null,
        )
        val linkedCalendarDraft = base.copy(id = "linked", sourceEventKey = "1:9:3600000")
        val trashed = base.copy(id = "trashed", trashedAtMs = 10)
        val recording = base.copy(id = "active", status = MobileMeetingStatus.RECORDING)

        val local = ReminderPlanner.localScheduledDrafts(listOf(base, linkedCalendarDraft, trashed, recording))
        assertEquals(1, local.size)
        assertEquals("local:local-draft-id", local.single().occurrenceId)
        assertEquals("local-draft-id", local.single().localMeetingId)
        assertTrue(ReminderPlanner.excludeCalendarDuplicates(local, listOf(event(1, begin, begin + 3_600_000L).copy(title = " LOCAL REVIEW "))).isEmpty())
        assertEquals(local, ReminderPlanner.excludeCalendarDuplicates(local, listOf(event(1, begin + 1, begin + 3_600_000L))))
        assertEquals(10, ReminderPlanner.DEFAULT_ALERT_MINUTES)
    }

    @Test fun staleOrMissingRecordingNotificationStopIdsCannotStopCurrentCapture() {
        assertTrue(notificationStopTargetsActiveRecording("recording-1", "recording-1"))
        assertFalse(notificationStopTargetsActiveRecording("recording-1", "recording-2"))
        assertFalse(notificationStopTargetsActiveRecording(null, "recording-2"))
    }

    @Test fun spanishMorningSummaryNamesTheNextMeetingWithA24HourTime() {
        val zone = ZoneOffset.UTC
        val nine = 9 * 3_600_000L
        assertEquals("Tu agenda de hoy está despejada. Guarda un poco de espacio para ti.", ReminderPlanner.summaryEs(emptyList(), 0, zone))
        assertEquals("Hoy tienes 1 reunión. Próxima: Meeting 1 a las 09:00.",
            ReminderPlanner.summaryEs(listOf(event(1, nine)), 0, zone))
        assertEquals("Hoy tienes 2 reuniones. Próxima: Meeting 2 a las 14:00.",
            ReminderPlanner.summaryEs(listOf(event(1, nine), event(2, 14 * 3_600_000L)), nine + 3_600_000L, zone))
        assertEquals("Hoy tienes 1 reunión. Ya terminaste por hoy.",
            ReminderPlanner.summaryEs(listOf(event(1, nine)), nine + 3_600_000L, zone))
    }
}
