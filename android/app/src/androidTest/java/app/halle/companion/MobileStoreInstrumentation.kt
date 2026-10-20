package app.halle.companion

import android.app.Instrumentation
import android.os.Bundle
import java.io.File
import java.util.UUID

/** Device-side regression for the partial-to-final rename and metadata commit boundary. */
class MobileStoreInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        try {
            verifyNormalFinalization()
            verifyInterruptedFinalization()
            verifyTrashedDraftCannotRecord()
            verifyHiddenOccurrenceRoundTrip()
            finish(0, Bundle().apply { putString("result", "passed") })
        } catch (failure: Throwable) {
            finish(1, Bundle().apply { putString("failure", failure.toString()) })
            throw failure
        }
    }

    private fun verifyNormalFinalization() {
        val store = MobileMeetingStore(targetContext)
        val meeting = store.createDraft("StoreRegressionTest ${UUID.randomUUID()}")
        try {
            val partial = requireNotNull(store.claimRecording(meeting.id)) { "Could not claim normal test recording" }
            partial.writeBytes(TEST_AUDIO_BYTES)
            check(store.markRecordingStarted(meeting.id)) { "Could not mark normal test recording started" }
            check(store.completeRecording(meeting.id, partial, 1250L)) { "Normal recording finalization failed" }
            check(store.find(meeting.id)?.status == MobileMeetingStatus.RECORDED) { "Finalized meeting metadata was not recorded" }
            check(File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/${meeting.id}.m4a").isFile) { "Final audio file is missing" }
            check(!partial.exists()) { "Partial audio file remains after finalization" }
            check(store.playbackUri(meeting.id) != null) { "Finalized audio cannot be opened for playback" }
        } finally {
            cleanup(store, meeting.id)
        }
    }

    private fun verifyInterruptedFinalization() {
        val store = MobileMeetingStore(targetContext)
        val meeting = store.createDraft("StoreRegressionTest ${UUID.randomUUID()}")
        try {
            val partial = requireNotNull(store.claimRecording(meeting.id)) { "Could not claim interrupted test recording" }
            partial.writeBytes(TEST_AUDIO_BYTES)
            check(store.markRecordingStarted(meeting.id)) { "Could not mark interrupted test recording started" }
            check(store.finalizeInterruptedRecording(meeting.id, partial, "Test interruption", 750L)) { "Interrupted recording finalization failed" }
            check(store.find(meeting.id)?.status == MobileMeetingStatus.INTERRUPTED) { "Interrupted metadata was not saved" }
            check(File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/${meeting.id}.m4a").isFile) { "Interrupted final audio file is missing" }
            check(!partial.exists()) { "Partial audio file remains after interrupted finalization" }
            check(store.playbackUri(meeting.id) != null) { "Finalized interrupted audio cannot be opened for playback" }
        } finally {
            cleanup(store, meeting.id)
        }
    }

    private fun cleanup(store: MobileMeetingStore, id: String) {
        File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/$id.m4a").delete()
        File(targetContext.filesDir, "${MobileMeetingStore.RECORDINGS_DIRECTORY}/$id.m4a.partial").delete()
        store.trash(id)
    }

    private fun verifyTrashedDraftCannotRecord() {
        val store = MobileMeetingStore(targetContext)
        val meeting = store.createDraft("StoreRegressionTest trashed ${UUID.randomUUID()}")
        check(store.trash(meeting.id))
        check(store.claimRecording(meeting.id) == null) { "A stale click opened a trashed draft for capture" }
        check(store.find(meeting.id)?.status == MobileMeetingStatus.DRAFT)
    }

    private fun verifyHiddenOccurrenceRoundTrip() {
        val store = LocalStore(targetContext)
        val key = "StoreRegressionTest:${UUID.randomUUID()}"
        check(!store.occurrenceHidden(key))
        store.hideOccurrence(key, true)
        check(store.occurrenceHidden(key)) { "Hidden calendar occurrence was not persisted" }
        store.hideOccurrence(key, false)
        check(!store.occurrenceHidden(key)) { "Restored calendar occurrence remains hidden" }
    }

    companion object {
        private val TEST_AUDIO_BYTES = byteArrayOf(0x00, 0x10, 0x20, 0x30, 0x40)
    }
}
