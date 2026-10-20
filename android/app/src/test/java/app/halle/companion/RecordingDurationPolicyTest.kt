package app.halle.companion

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingDurationPolicyTest {
    @Test
    fun discardsOnlyConfirmedCapturesStrictlyBelowTenSeconds() {
        assertTrue(RecordingDurationPolicy.shouldDiscard(9_999L))
        assertTrue(RecordingDurationPolicy.shouldDiscard(0L))
        assertFalse(RecordingDurationPolicy.shouldDiscard(10_000L))
        assertFalse(RecordingDurationPolicy.shouldDiscard(10_001L))
        assertFalse(RecordingDurationPolicy.shouldDiscard(-1L))
    }
}
