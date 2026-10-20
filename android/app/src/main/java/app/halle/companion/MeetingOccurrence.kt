package app.halle.companion

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

data class MeetingOccurrence(
    val calendarId: Long,
    val eventId: Long,
    val beginMillis: Long,
    val endMillis: Long,
    val title: String,
    val location: String?,
    val allDay: Boolean,
    val canceled: Boolean,
    val declined: Boolean,
    val meetingUrl: String?,
    val calendarName: String,
) {
    val occurrenceId: String get() = "$calendarId:$eventId:$beginMillis"
    val eventKey: String get() = "$calendarId:$eventId"
    fun startsAt(zone: ZoneId = ZoneId.systemDefault()): String =
        if (allDay) "All day" else DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault())
            .withZone(zone).format(Instant.ofEpochMilli(beginMillis))
    fun endsAt(zone: ZoneId = ZoneId.systemDefault()): String =
        DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault()).withZone(zone)
            .format(Instant.ofEpochMilli(endMillis))
}

data class CalendarChoice(val id: Long, val name: String, val account: String, val ownerAccount: String, val color: Int)
