package app.halle.companion

import app.halle.companion.MobileMeetingStatus.*
import app.halle.companion.PhoneRecordingAction.*
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class OrbitaBridgePolicyTest {
    @Test fun oversizedBridgeMessagesAreDroppedBeforeParsing() {
        assertTrue(OrbitaBridgePolicy.accepts("refresh", "{}"))
        assertTrue(OrbitaBridgePolicy.accepts("a".repeat(40), "x".repeat(4096)))
        assertFalse(OrbitaBridgePolicy.accepts("a".repeat(41), "{}"))
        assertFalse(OrbitaBridgePolicy.accepts("refresh", "x".repeat(4097)))
        assertFalse(OrbitaBridgePolicy.accepts("", "{}"))
    }

    @Test fun stagingBlocksOnlyThePairingEntryPoints() {
        for (action in listOf("scanQr", "pair")) {
            assertTrue(OrbitaBridgePolicy.blockedInStaging(action, staging = true))
            assertFalse(OrbitaBridgePolicy.blockedInStaging(action, staging = false))
        }
        for (action in listOf("accountCalendar", "quickRecord", "trashList", "deleteMeeting"))
            assertFalse(OrbitaBridgePolicy.blockedInStaging(action, staging = true))
        assertTrue(OrbitaBridgePolicy.STAGING_PAIRING_NOTE.contains("staging"))
    }

    @Test fun webViewTextFollowsTheSystemFontScale() {
        assertEquals(100, OrbitaBridgePolicy.textZoom(1f))
        assertEquals(130, OrbitaBridgePolicy.textZoom(1.3f))
        assertEquals(85, OrbitaBridgePolicy.textZoom(0.85f))
        assertEquals(300, OrbitaBridgePolicy.textZoom(9f))
        assertEquals(100, OrbitaBridgePolicy.textZoom(0f))
        assertEquals(100, OrbitaBridgePolicy.textZoom(Float.NaN))
    }

    @Test fun accountCalendarOpensOnTheSelectedDayOrFallsBack() {
        val today = LocalDate.of(2026, 11, 27)
        assertEquals("2026-12-03", OrbitaBridgePolicy.accountCalendarDay("2026-12-03", today))
        assertEquals("2026-11-27", OrbitaBridgePolicy.accountCalendarDay("2026-13-40", today))
        assertEquals("2026-11-27", OrbitaBridgePolicy.accountCalendarDay("", today))
        assertEquals("2026-11-27", OrbitaBridgePolicy.accountCalendarDay(null, today))
        assertEquals("2026-11-27", OrbitaBridgePolicy.accountCalendarDay("2026-12-03T00:00", today))
    }

    @Test fun libraryActionsFollowPhoneRecordingPolicy() {
        assertEquals(listOf(PLAY, SHARE_AUDIO, DELETE), OrbitaBridgePolicy.recordingActions(RECORDED, finalAudio = true, partialAudio = false))
        // Interrupted with only the raw partial file: share it or delete it, never a dead end.
        assertEquals(listOf(SHARE_PARTIAL_FILE, DELETE), OrbitaBridgePolicy.recordingActions(INTERRUPTED, finalAudio = false, partialAudio = true))
        assertEquals(listOf(DELETE), OrbitaBridgePolicy.recordingActions(INTERRUPTED, finalAudio = false, partialAudio = false))
        // A meeting saved without recording can be deleted.
        assertEquals(listOf(DELETE), OrbitaBridgePolicy.recordingActions(DRAFT, finalAudio = false, partialAudio = false))
        // Nothing while the recorder may still be writing.
        assertEquals(emptyList<PhoneRecordingAction>(), OrbitaBridgePolicy.recordingActions(RECORDING, finalAudio = true, partialAudio = true))
        assertEquals(emptyList<PhoneRecordingAction>(), OrbitaBridgePolicy.recordingActions(STARTING, finalAudio = false, partialAudio = true))
        // A finalized file on a draft is never offered for playback.
        assertEquals(listOf(DELETE), OrbitaBridgePolicy.recordingActions(DRAFT, finalAudio = true, partialAudio = false))
    }
}
