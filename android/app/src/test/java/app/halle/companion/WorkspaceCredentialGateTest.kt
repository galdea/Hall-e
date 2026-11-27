package app.halle.companion

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceCredentialGateTest {
    @Test fun activeCredentialOperationPreventsReplacementReservation() {
        val gate = WorkspaceCredentialGate()
        assertTrue(gate.beginOperation())
        assertFalse(gate.reserveReplacement { true })
        gate.endOperation()
        assertTrue(gate.reserveReplacement { true })
        gate.finishReplacement()
    }

    @Test fun replacementReservationBlocksCaptureAndStaysReservedUntilReleased() {
        val gate = WorkspaceCredentialGate()
        assertTrue(gate.reserveReplacement { true })
        assertFalse(gate.beginOperation())
        gate.finishReplacement()
        assertTrue(gate.beginOperation())
        gate.endOperation()
    }

    @Test fun unsafeWorkspaceStateDoesNotReserveReplacement() {
        val gate = WorkspaceCredentialGate()
        assertFalse(gate.reserveReplacement { false })
        assertTrue(gate.beginOperation())
        gate.endOperation()
    }
}
