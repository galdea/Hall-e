package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class MeetingFieldPreservationTest {
    @Test fun fieldsFromAnotherBuildAreKeptAndKnownFieldsAreNot() {
        // A meeting as Órbita 0.3.1 stores it, including phone-to-Mac transfer and discard state.
        val stored = JSONObject()
            .put("id", "3198002a-77a1-4309-8963-68e6bdc8cfff").put("title", "Reunión").put("status", "RECORDED")
            .put("transferState", "RECEIPTED").put("transferReceiptJson", "{\"v\":1}").put("transferEnrolledAtMs", 42L)
            .put("discardFinalReason", "short")
        val kept = preservedMeetingFields(stored)
        assertEquals(setOf("transferState", "transferReceiptJson", "transferEnrolledAtMs", "discardFinalReason"), kept.keys().asSequence().toSet())
        assertEquals("RECEIPTED", kept.getString("transferState"))
        assertEquals(42L, kept.getLong("transferEnrolledAtMs"))
        assertFalse(kept.has("title"))
    }
}
