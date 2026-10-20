package app.halle.companion

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import java.net.URI

class CalendarRepository(private val context: Context, private val store: LocalStore) {
    fun hasPermission(): Boolean = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    fun calendars(): List<CalendarChoice> {
        if (!hasPermission()) return emptyList()
        val result = mutableListOf<CalendarChoice>()
        val projection = arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME, CalendarContract.Calendars.OWNER_ACCOUNT,
            CalendarContract.Calendars.CALENDAR_COLOR)
        context.contentResolver.query(CalendarContract.Calendars.CONTENT_URI, projection, null, null,
            "${CalendarContract.Calendars.CALENDAR_DISPLAY_NAME} COLLATE NOCASE")?.use { cursor ->
            while (cursor.moveToNext()) result += CalendarChoice(cursor.long(0), cursor.string(1), cursor.string(2),
                cursor.string(3), cursor.getInt(4))
        }
        if (!store.calendarsInitialized && result.isNotEmpty()) {
            store.selectedCalendarIds = result.map { it.id }.toSet()
            store.calendarsInitialized = true
        }
        return result
    }

    fun events(fromMillis: Long, toMillis: Long): List<MeetingOccurrence> {
        if (!hasPermission()) return emptyList()
        val choices = calendars().associateBy { it.id }
        val selected = choices.keys.intersect(store.selectedCalendarIds)
        if (selected.isEmpty()) return emptyList()
        // Calendar all-day events are stored against UTC day boundaries. Pad the query so
        // dates on either side of the device's UTC offset can still be filtered correctly.
        val padding = 24L * 60 * 60 * 1000
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
            .appendPath((fromMillis - padding).toString()).appendPath((toMillis + padding).toString()).build()
        val ids = selected.joinToString(",") { "?" }
        val args = selected.map(Long::toString).toTypedArray()
        val projection = arrayOf(CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.BEGIN, CalendarContract.Instances.END, CalendarContract.Instances.TITLE,
            CalendarContract.Instances.EVENT_LOCATION, CalendarContract.Instances.ALL_DAY)
        val base = mutableListOf<MeetingOccurrence>()
        context.contentResolver.query(uri, projection, "${CalendarContract.Instances.CALENDAR_ID} IN ($ids)", args,
            "${CalendarContract.Instances.BEGIN} ASC")?.use { cursor ->
            while (cursor.moveToNext()) {
                val eventId = cursor.long(0)
                val calendarId = cursor.long(1)
                val details = eventDetails(eventId)
                val choice = choices[calendarId]
                base += MeetingOccurrence(calendarId, eventId, cursor.long(2), cursor.long(3),
                    cursor.string(4).ifBlank { "Untitled event" }, cursor.stringOrNull(5), cursor.getInt(6) != 0,
                    details.canceled, declined(eventId, choice?.account), safeMeetingLink(details.customUri, details.description),
                    choice?.name ?: "Calendar")
            }
        }
        return base.filterNot { it.canceled || it.declined }.distinctBy { it.occurrenceId }
    }

    private data class EventDetails(val canceled: Boolean, val description: String?, val customUri: String?)

    private fun eventDetails(eventId: Long): EventDetails {
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
        val projection = arrayOf(CalendarContract.Events.STATUS, CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.CUSTOM_APP_URI)
        context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return EventDetails(cursor.getInt(0) == CalendarContract.Events.STATUS_CANCELED,
                cursor.stringOrNull(1), cursor.stringOrNull(2))
        }
        return EventDetails(false, null, null)
    }

    private fun declined(eventId: Long, accountName: String?): Boolean {
        if (accountName.isNullOrBlank()) return false
        val uri = CalendarContract.Attendees.CONTENT_URI
        val projection = arrayOf(CalendarContract.Attendees.ATTENDEE_EMAIL, CalendarContract.Attendees.ATTENDEE_STATUS)
        context.contentResolver.query(uri, projection, "${CalendarContract.Attendees.EVENT_ID} = ?",
            arrayOf(eventId.toString()), null)?.use { cursor ->
            while (cursor.moveToNext()) if (cursor.getString(0).equals(accountName, ignoreCase = true)
                && cursor.getInt(1) == CalendarContract.Attendees.ATTENDEE_STATUS_DECLINED) return true
        }
        return false
    }

    private fun safeMeetingLink(custom: String?, description: String?): String? {
        val candidates = listOfNotNull(custom) + Regex("https?://[^\\s<>\\\"]+").findAll(description.orEmpty()).map { it.value.trimEnd('.', ',', ')', ']') }.toList()
        return candidates.firstNotNullOfOrNull { raw ->
            runCatching {
                val uri = URI(raw)
                val host = uri.host?.lowercase() ?: return@runCatching null
                val allowed = host == "meet.google.com" || host.endsWith(".zoom.us") || host == "zoom.us"
                    || host == "teams.microsoft.com" || host == "teams.live.com" || host == "webex.com" || host.endsWith(".webex.com")
                if (uri.scheme == "https" && allowed) uri.toASCIIString() else null
            }.getOrNull()
        }
    }

    private fun Cursor.long(index: Int): Long = if (isNull(index)) 0 else getLong(index)
    private fun Cursor.string(index: Int): String = if (isNull(index)) "" else getString(index).orEmpty()
    private fun Cursor.stringOrNull(index: Int): String? = if (isNull(index)) null else getString(index)
}
