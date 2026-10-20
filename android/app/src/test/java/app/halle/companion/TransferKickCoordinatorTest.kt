package app.halle.companion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferKickCoordinatorTest {
    @Test fun routineKickLeavesPendingBackoffInPlace() {
        val port = FakeKickPort(pendingJob = true)

        TransferKickCoordinator.kick(port, prioritizeNow = false)

        assertEquals(listOf("running?", "pending?"), port.calls)
        assertTrue(port.pendingJob)
        assertEquals(0, port.scheduleCount)
    }

    @Test fun urgentKickReplacesPendingBackoffAndSchedulesFreshJob() {
        val port = FakeKickPort(pendingJob = true)

        TransferKickCoordinator.kick(port, prioritizeNow = true)

        assertEquals(listOf("running?", "pending?", "cancel", "running?", "schedule"), port.calls)
        assertTrue(port.pendingJob)
        assertEquals(1, port.scheduleCount)
    }

    @Test fun urgentKickDuringActiveRunRequestsOnePrioritizedFollowUp() {
        val port = FakeKickPort(running = true)

        TransferKickCoordinator.kick(port, prioritizeNow = true)

        assertEquals(listOf("running?"), port.calls)
        assertTrue(port.rerunRequested)
        assertTrue(port.rerunPrioritized)
        assertEquals(0, port.scheduleCount)
    }

    @Test fun workerStartingDuringPendingCancellationGetsFollowUpInsteadOfDuplicateSchedule() {
        val port = FakeKickPort(pendingJob = true, startWorkerWhenCanceled = true)

        TransferKickCoordinator.kick(port, prioritizeNow = true)

        assertTrue(port.rerunRequested)
        assertTrue(port.rerunPrioritized)
        assertEquals(0, port.scheduleCount)
    }

    private class FakeKickPort(
        var running: Boolean = false,
        var pendingJob: Boolean = false,
        private val startWorkerWhenCanceled: Boolean = false,
    ) : TransferKickPort {
        val calls = mutableListOf<String>()
        var rerunRequested = false
        var rerunPrioritized = false
        var scheduleCount = 0

        override fun requestAnotherRunIfRunning(prioritizeNow: Boolean): Boolean {
            calls += "running?"
            if (!running) return false
            rerunRequested = true
            rerunPrioritized = rerunPrioritized || prioritizeNow
            return true
        }

        override fun hasPendingJob(): Boolean {
            calls += "pending?"
            return pendingJob
        }

        override fun cancelPendingJob() {
            calls += "cancel"
            pendingJob = false
            if (startWorkerWhenCanceled) running = true
        }

        override fun schedule() {
            calls += "schedule"
            scheduleCount++
            pendingJob = true
        }
    }
}
