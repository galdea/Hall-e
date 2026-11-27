package app.halle.companion

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime

class OrbitaStyleTest {
    private val zone = ZoneId.of("America/Santiago")
    private fun at(date: String, time: String) = ZonedDateTime.of(LocalDate.parse(date), LocalTime.parse(time), zone)

    @Test fun contrastRatioMatchesWcagReferenceValues() {
        assertEquals(21.0, contrastRatio(0xFF000000.toInt(), 0xFFFFFFFF.toInt()), 0.01)
        assertEquals(1.0, contrastRatio(OrbitaColors.BG, OrbitaColors.BG), 0.0001)
        assertEquals(contrastRatio(OrbitaColors.MUTED, OrbitaColors.BG), contrastRatio(OrbitaColors.BG, OrbitaColors.MUTED), 0.0001)
    }

    @Test fun everyTextPairingMeetsAaForNormalText() {
        val pairs = mapOf(
            "text on bg" to (OrbitaColors.TEXT to OrbitaColors.BG),
            "text on panel" to (OrbitaColors.TEXT to OrbitaColors.PANEL),
            "text on message band" to (OrbitaColors.TEXT to OrbitaColors.MESSAGE),
            "text on pressed" to (OrbitaColors.TEXT to OrbitaColors.PRESSED),
            "muted on bg" to (OrbitaColors.MUTED to OrbitaColors.BG),
            "muted on panel" to (OrbitaColors.MUTED to OrbitaColors.PANEL),
            "mint on bg" to (OrbitaColors.MINT to OrbitaColors.BG),
            "mint on panel" to (OrbitaColors.MINT to OrbitaColors.PANEL),
            "on-mint on mint" to (OrbitaColors.ON_MINT to OrbitaColors.MINT),
            "on-mint on pressed mint" to (OrbitaColors.ON_MINT to OrbitaColors.MINT_PRESSED),
            "danger on danger bg" to (OrbitaColors.DANGER_TEXT to OrbitaColors.DANGER_BG),
            "danger on bg" to (OrbitaColors.DANGER_TEXT to OrbitaColors.BG),
            "danger on panel" to (OrbitaColors.DANGER_TEXT to OrbitaColors.PANEL),
            "recording on bg" to (OrbitaColors.RECORDING to OrbitaColors.BG),
            "recording on panel" to (OrbitaColors.RECORDING to OrbitaColors.PANEL),
        )
        for ((name, pair) in pairs) {
            val ratio = contrastRatio(pair.first, pair.second)
            assertTrue("$name is $ratio:1", ratio >= 4.5)
        }
    }

    @Test fun recordingStatusesAreSpanishAndUnknownOnesPassThrough() {
        assertEquals("Transcrita", AgendaCopy.recordingStatus("completed"))
        assertEquals("Necesita revisión", AgendaCopy.recordingStatus("review"))
        assertEquals("Transcribiendo", AgendaCopy.recordingStatus("processing"))
        assertEquals("future_state", AgendaCopy.recordingStatus("future_state"))
        for (status in MobileMeetingStatus.values()) assertTrue(AgendaCopy.phoneStatus(status).isNotBlank())
    }

    @Test fun phoneRecordingLineKeepsTheOriginalPrecedence() {
        val recorded = MobileMeetingStatus.RECORDED
        val problem = JSONObject().put("provider", "deepgram").put("problem", 413)
        val queued = JSONObject().put("provider", "speechmatics")
        assertEquals("Grabada · la subida necesita atención (HTTP 413)",
            AgendaCopy.phoneRecordingLine(recorded, problem, staging = true, uploaded = true))
        assertEquals("Grabada · en cola para staging", AgendaCopy.phoneRecordingLine(recorded, queued, staging = true, uploaded = true))
        assertEquals("Grabada · en cola para Speechmatics · UE",
            AgendaCopy.phoneRecordingLine(recorded, queued, staging = false, uploaded = true))
        assertEquals("Grabada · subida a tu cuenta", AgendaCopy.phoneRecordingLine(recorded, null, staging = false, uploaded = true))
        assertEquals("Interrumpida · solo en este teléfono",
            AgendaCopy.phoneRecordingLine(MobileMeetingStatus.INTERRUPTED, null, staging = false, uploaded = false))
    }

    @Test fun deletePhoneCopyMessageNamesOnlyWhatApplies() {
        val plain = AgendaCopy.deletePhoneCopyMessage(queued = false, uploaded = false)
        assertTrue(plain.contains("No se puede deshacer"))
        assertFalse(plain.contains("subida"))
        assertFalse(plain.contains("subiste"))
        assertTrue(AgendaCopy.deletePhoneCopyMessage(queued = true, uploaded = false).contains("Su subida pendiente se cancela."))
        assertTrue(AgendaCopy.deletePhoneCopyMessage(queued = false, uploaded = true).contains("ya subiste a tu cuenta no cambia"))
    }

    @Test fun datesReadInChileanSpanish() {
        val today = LocalDate.parse("2026-11-27")
        assertEquals("viernes 27 de noviembre", AgendaCopy.dayLabel(today, today))
        assertEquals("lunes 4 de enero de 2027", AgendaCopy.dayLabel(LocalDate.parse("2027-01-04"), today))
        assertEquals("10:00 – 10:30", AgendaCopy.timeRange(at("2026-11-27", "10:00"), at("2026-11-27", "10:30")))
        assertEquals("27/11 23:30 – 28/11 00:15", AgendaCopy.timeRange(at("2026-11-27", "23:30"), at("2026-11-28", "00:15")))
        assertEquals("31/12 23:00 – 01/01 01:00 (2027)", AgendaCopy.timeRange(at("2026-12-31", "23:00"), at("2027-01-01", "01:00")))
        assertEquals("27/11", AgendaCopy.rowDate(at("2026-11-27", "09:05")))
        assertEquals("09:05", AgendaCopy.rowTime(at("2026-11-27", "09:05")))
        assertEquals("Sincronizado a las 14:03:09", AgendaCopy.syncedAt(LocalTime.of(14, 3, 9, 500)))
    }

    @Test fun providerNamesAndTypedConfirmationStayStable() {
        assertEquals("Deepgram", AgendaCopy.providerName("deepgram"))
        assertEquals("Speechmatics · UE", AgendaCopy.providerName("speechmatics"))
        // The typed word is a server contract and stays English even though the screen is Spanish.
        assertEquals("DELETE", ACCOUNT_DELETION_CONFIRMATION)
    }
}
