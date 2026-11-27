package app.halle.companion

import java.time.LocalDate
import kotlin.math.roundToInt

/** Pure decisions for the Órbita WebView host ([MainActivity]); unit-tested without a WebView. */
internal object OrbitaBridgePolicy {
    const val MAX_ACTION_LENGTH = 40
    const val MAX_PAYLOAD_LENGTH = 4096

    /** Actions that open pairing and so would reach the production coordinator. */
    val PAIRING_ACTIONS = setOf("scanQr", "pair")

    const val STAGING_PAIRING_NOTE =
        "Vincular dispositivos no está disponible en esta versión de staging porque usa el servicio de vinculación de producción."

    /** Oversized messages are dropped before parsing. */
    fun accepts(action: String, raw: String): Boolean =
        action.isNotEmpty() && action.length <= MAX_ACTION_LENGTH && raw.length <= MAX_PAYLOAD_LENGTH

    /** Staging builds never open pairing, mirroring the native fence on main ([SharedSessionActivity] finishes too). */
    fun blockedInStaging(action: String, staging: Boolean): Boolean = staging && action in PAIRING_ACTIONS

    /** WebView text zoom that follows Android's font size setting (100 = default). */
    fun textZoom(fontScale: Float): Int =
        if (fontScale.isNaN() || fontScale <= 0f) 100 else (fontScale * 100f).roundToInt().coerceIn(50, 300)

    /** The day the private account calendar opens on: the selected calendar day, or [fallback] when invalid. */
    fun accountCalendarDay(raw: String?, fallback: LocalDate): String =
        raw?.takeIf { it.length == 10 }?.let { runCatching { LocalDate.parse(it) }.getOrNull() }?.toString() ?: fallback.toString()

    /**
     * Library actions for one personal meeting, delegated to [personalRecordingActions] so the rules live in one place.
     * [finalAudio]: `<id>.m4a` exists and is the meeting's file; [partialAudio]: only the raw `.m4a.partial` remains.
     */
    fun recordingActions(status: MobileMeetingStatus, finalAudio: Boolean, partialAudio: Boolean): List<PhoneRecordingAction> =
        personalRecordingActions(
            status,
            playable = finalAudio && (status == MobileMeetingStatus.RECORDED || status == MobileMeetingStatus.INTERRUPTED),
            partialFile = partialAudio && status == MobileMeetingStatus.INTERRUPTED,
        )
}
