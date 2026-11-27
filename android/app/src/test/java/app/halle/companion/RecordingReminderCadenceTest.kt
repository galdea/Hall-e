package app.halle.companion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingReminderCadenceTest {
    private class FakeTime {
        var now = 0L
        val tasks = mutableListOf<Pair<Runnable, Long>>()
        fun schedule(runnable: Runnable, delay: Long) { tasks += runnable to (now + delay) }
        fun cancel(runnable: Runnable) { tasks.removeAll { it.first === runnable } }
        fun advanceTo(time: Long) {
            now = time
            while (true) {
                val next = tasks.minByOrNull { it.second } ?: return
                if (next.second > now) return
                tasks.remove(next)
                next.first.run()
            }
        }
        fun hasTasks() = tasks.isNotEmpty()
        fun nextDelay() = tasks.minOf { it.second } - now
    }

    @Test fun pulsesOnFiveMinuteCadenceAndStopsWhenRecordingStops() {
        val time = FakeTime()
        var pulses = 0
        val cadence = RecordingReminderCadence(time::schedule, time::cancel, { time.now }, { pulses++ })

        cadence.start()
        time.advanceTo(RecordingReminderCadence.INTERVAL_MS - 1)
        assertEquals(0, pulses)
        time.advanceTo(RecordingReminderCadence.INTERVAL_MS)
        assertEquals(1, pulses)
        time.advanceTo(2 * RecordingReminderCadence.INTERVAL_MS)
        assertEquals(2, pulses)

        cadence.stop()
        assertFalse(time.hasTasks())
        time.advanceTo(4 * RecordingReminderCadence.INTERVAL_MS)
        assertEquals(2, pulses)
    }

    @Test fun delayedWakeDoesNotBurstMissedPulses() {
        val time = FakeTime()
        var pulses = 0
        val cadence = RecordingReminderCadence(time::schedule, time::cancel, { time.now }, { pulses++ })
        cadence.start()

        time.advanceTo(17 * 60_000L)
        assertEquals(1, pulses)
        assertTrue(time.nextDelay() in 1L..RecordingReminderCadence.INTERVAL_MS)
        cadence.stop()
        assertFalse(time.hasTasks())
    }
}
