package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import java.nio.charset.StandardCharsets
import java.util.Base64

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

    @Test
    fun desktopInvitationQrParsesWithSameValidatedPayload() {
        val link = SharedSessionClient.makePairingLink(
            SharedSessionClient.PRODUCTION_ENDPOINT,
            "workspace-123",
            "i".repeat(32),
            ByteArray(32) { it.toByte() },
        )

        val parsed = SharedSessionClient.parsePairingInput(link, SharedSessionClient.PRODUCTION_ENDPOINT)

        assertEquals(SharedSessionClient.PRODUCTION_ENDPOINT, parsed.endpoint)
        assertEquals("workspace-123", parsed.workspaceId)
        assertEquals("i".repeat(32), parsed.inviteToken)
        assertEquals(ByteArray(32) { it.toByte() }.toList(), parsed.workspaceKey.toList())
    }

    @Test
    fun invitationQrRejectsUnapprovedCoordinatorWithoutExposingPayload() {
        val payload = JSONObject()
            .put("v", 1).put("endpoint", "https://example.invalid")
            .put("workspaceId", "workspace-123").put("inviteToken", "i".repeat(32))
            .put("key", Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32)))
        val encoded = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(payload.toString().toByteArray(StandardCharsets.UTF_8))
        val link = SharedSessionClient.PAIRING_PAGE + "#" + encoded
        try {
            SharedSessionClient.parsePairingInput(link, SharedSessionClient.PRODUCTION_ENDPOINT)
            fail("Expected unapproved coordinator to be rejected")
        } catch (_: IllegalArgumentException) {
            // Validation errors are deliberately generic and never include the scanned QR value.
        }
    }
}
