package app.halle.companion

import android.content.Context
import java.time.LocalDate

class LocalStore(context: Context) {
    private val prefs = context.getSharedPreferences("halle-local", Context.MODE_PRIVATE)

    var alertMinutes: Int
        get() = prefs.getInt("alertMinutes", 5)
        set(value) { prefs.edit().putInt("alertMinutes", value.coerceIn(0, 1440)).apply() }
    var morningSummaryEnabled: Boolean
        get() = prefs.getBoolean("morningSummaryEnabled", true)
        set(value) { prefs.edit().putBoolean("morningSummaryEnabled", value).apply() }
    var selectedCalendarIds: Set<Long>
        get() = prefs.getStringSet("calendarIds", emptySet())?.mapNotNull(String::toLongOrNull)?.toSet().orEmpty()
        set(value) { prefs.edit().putStringSet("calendarIds", value.map(Long::toString).toSet()).apply() }
    var calendarsInitialized: Boolean
        get() = prefs.getBoolean("calendarsInitialized", false)
        set(value) { prefs.edit().putBoolean("calendarsInitialized", value).apply() }
    var scheduledOccurrenceIds: Set<String>
        get() = prefs.getStringSet("scheduledOccurrenceIds", emptySet()).orEmpty()
        set(value) { prefs.edit().putStringSet("scheduledOccurrenceIds", value).apply() }

    var deliveredOccurrenceIds: Set<String>
        get() = prefs.getStringSet("deliveredOccurrenceIds", emptySet()).orEmpty()
        set(value) { prefs.edit().putStringSet("deliveredOccurrenceIds", value).commit() }

    fun claimDelivery(deliveryKey: String): Boolean = synchronized(deliveryLock) {
        val delivered = deliveredDeliveryKeys
        if (deliveryKey in delivered) false
        else {
            prefs.edit().putStringSet("deliveredDeliveryKeys", delivered + deliveryKey).commit()
        }
    }

    fun releaseDelivery(deliveryKey: String): Boolean = synchronized(deliveryLock) {
        prefs.edit().putStringSet("deliveredDeliveryKeys", deliveredDeliveryKeys - deliveryKey).commit()
    }

    private var deliveredDeliveryKeys: Set<String>
        get() = prefs.getStringSet("deliveredDeliveryKeys", emptySet()).orEmpty()
        set(value) { prefs.edit().putStringSet("deliveredDeliveryKeys", value).commit() }

    companion object {
        private val deliveryLock = Any()
    }

    fun morningSummaryFor(date: LocalDate): Boolean {
        val today = date.toString()
        if (prefs.getString("morningSummaryShown", null) == today) return false
        prefs.edit().putString("morningSummaryShown", today).apply()
        return true
    }

    fun projectFor(eventKey: String): String? = prefs.getString("project:$eventKey", null)
    fun assignProject(eventKey: String, name: String?) {
        prefs.edit().apply { if (name == null) remove("project:$eventKey") else putString("project:$eventKey", name) }.apply()
    }
    fun projects(): List<String> = prefs.getStringSet("projects", emptySet()).orEmpty().sortedBy(String::lowercase)
    fun addProject(name: String): String {
        val clean = name.trim().take(80)
        if (clean.isNotEmpty()) prefs.edit().putStringSet("projects", projects().toSet() + clean).apply()
        return clean
    }
    fun noteFor(eventKey: String): String = prefs.getString("note:$eventKey", "").orEmpty()
    fun saveNote(eventKey: String, markdown: String) {
        prefs.edit().putString("note:$eventKey", markdown.take(20_000)).apply()
    }
}
