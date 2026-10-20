package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SharedSessionParsingTest {
    @Test
    fun nullableStringTreatsJsonNullAndMissingAsNull() {
        val json = JSONObject("{\"nullValue\":null,\"missingValue\":\"\"}")

        assertNull(json.optNullableString("nullValue"))
        assertNull(json.optNullableString("missingValue"))
        assertNull(json.optNullableString("absent"))
    }

    @Test
    fun nullableStringReturnsNonBlankString() {
        val json = JSONObject("{\"deviceId\":\"device-123\"}")

        assertEquals("device-123", json.optNullableString("deviceId"))
    }
}
