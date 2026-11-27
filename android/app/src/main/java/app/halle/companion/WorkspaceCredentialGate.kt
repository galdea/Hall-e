package app.halle.companion

/** Serializes credential replacement against capture preparation and recording startup. */
internal class WorkspaceCredentialGate {
    private val lock = Any()
    private var activeOperations = 0
    private var replacementReserved = false

    fun beginOperation(): Boolean = synchronized(lock) {
        if (replacementReserved) return@synchronized false
        activeOperations++
        true
    }

    fun endOperation() = synchronized(lock) {
        check(activeOperations > 0) { "No workspace operation is active." }
        activeOperations--
    }

    fun reserveReplacement(safeToReplace: () -> Boolean): Boolean = synchronized(lock) {
        if (replacementReserved || activeOperations != 0 || !safeToReplace()) return@synchronized false
        replacementReserved = true
        true
    }

    fun finishReplacement() = synchronized(lock) {
        check(replacementReserved) { "No workspace replacement is reserved." }
        replacementReserved = false
    }
}
