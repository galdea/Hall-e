package app.halle.companion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LeaseDeadlineTest {
    @Test
    fun expiredLeaseCannotBeRevivedByLateRenewal() {
        var now = 100L
        val deadline = LeaseDeadline(110L) { now }

        now = 110L
        assertFalse(deadline.isValid())
        deadline.extendTo(200L)

        assertEquals(110L, deadline.deadlineElapsedMs)
        assertFalse(deadline.isValid())
    }

    @Test
    fun failedRenewalDoesNotExtendTheLastConfirmedDeadline() {
        var now = 10L
        val deadline = LeaseDeadline(50L) { now }

        now = 12L
        deadline.tighten(now + 15L)
        // A network failure has no confirmation to pass to extendTo.
        now = 27L

        assertEquals(27L, deadline.deadlineElapsedMs)
        assertFalse(deadline.isValid())
    }

    @Test
    fun requestStartDeadlineCanOnlyTightenUntilRenewalIsConfirmed() {
        var now = 10L
        val deadline = LeaseDeadline(30L) { now }

        deadline.tighten(40L)
        assertEquals(30L, deadline.deadlineElapsedMs)

        deadline.tighten(20L)
        assertEquals(20L, deadline.deadlineElapsedMs)

        now = 15L
        deadline.extendTo(35L)
        assertEquals(35L, deadline.deadlineElapsedMs)
        assertTrue(deadline.isValid())
    }
}
