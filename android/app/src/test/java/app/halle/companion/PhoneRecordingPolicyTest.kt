package app.halle.companion

import app.halle.companion.MobileMeetingStatus.*
import app.halle.companion.PhoneRecordingAction.*
import org.junit.Assert.*
import org.junit.Test

class PhoneRecordingPolicyTest {
    @Test fun recordingInProgressCannotBeDeleted() {
        assertFalse(canDeleteRecording(STARTING))
        assertFalse(canDeleteRecording(RECORDING))
        for (status in listOf(DRAFT, RECORDED, INTERRUPTED, FAILED)) assertTrue(canDeleteRecording(status))
    }

    @Test fun personalLibraryOffersDeleteForFinishedRecordingsOnly() {
        assertEquals(listOf(PLAY, SHARE_AUDIO, DELETE), personalRecordingActions(RECORDED, playable = true, partialFile = false))
        assertEquals(listOf(DELETE), personalRecordingActions(RECORDED, playable = false, partialFile = false))
        assertEquals(listOf(PLAY, SHARE_AUDIO, DELETE), personalRecordingActions(INTERRUPTED, playable = true, partialFile = false))
        assertEquals(listOf(SHARE_PARTIAL_FILE, DELETE), personalRecordingActions(INTERRUPTED, playable = false, partialFile = true))
        assertEquals(listOf(DELETE), personalRecordingActions(FAILED, playable = false, partialFile = false))
        // Stop first: nothing, and certainly not Delete, while the recorder may still be writing.
        assertEquals(emptyList<PhoneRecordingAction>(), personalRecordingActions(STARTING, playable = false, partialFile = false))
        assertEquals(emptyList<PhoneRecordingAction>(), personalRecordingActions(RECORDING, playable = true, partialFile = true))
        // A meeting saved without recording can be deleted too, so a mistaken meeting never stays stuck on the phone.
        assertEquals(listOf(DELETE), personalRecordingActions(DRAFT, playable = false, partialFile = false))
    }

    @Test fun interruptedAccountRecordingIsNeverADeadEnd() {
        // A raw .m4a.partial from a killed process: no Play and no upload, but it can be deleted.
        assertEquals(listOf(DELETE), accountRecordingActions(INTERRUPTED, playable = false, queued = false,
            uploadProblem = false, uploaded = false))
        // MediaRecorder finalized the interrupted file: the existing play and send actions remain.
        assertEquals(listOf(PLAY, SEND, DELETE), accountRecordingActions(INTERRUPTED, playable = true, queued = false,
            uploadProblem = false, uploaded = false))
        assertEquals(listOf(PLAY, DELETE), accountRecordingActions(INTERRUPTED, playable = true, queued = true,
            uploadProblem = false, uploaded = false))
        assertEquals(listOf(PLAY, RETRY_UPLOAD, CANCEL_UPLOAD, DELETE), accountRecordingActions(INTERRUPTED, playable = true,
            queued = true, uploadProblem = true, uploaded = false))
        assertEquals(listOf(DELETE), accountRecordingActions(FAILED, playable = false, queued = false,
            uploadProblem = false, uploaded = false))
    }

    @Test fun accountRecordingKeepsExistingActionsForOtherStates() {
        assertEquals(listOf(STOP), accountRecordingActions(RECORDING, playable = false, queued = true,
            uploadProblem = false, uploaded = false))
        assertEquals(listOf(STOP), accountRecordingActions(STARTING, playable = false, queued = false,
            uploadProblem = false, uploaded = false))
        assertEquals(listOf(PLAY, SEND), accountRecordingActions(RECORDED, playable = true, queued = false,
            uploadProblem = false, uploaded = false))
        assertEquals(listOf(PLAY), accountRecordingActions(RECORDED, playable = true, queued = false,
            uploadProblem = false, uploaded = true))
        assertEquals(listOf(PLAY, RETRY_UPLOAD, CANCEL_UPLOAD), accountRecordingActions(RECORDED, playable = true,
            queued = true, uploadProblem = true, uploaded = false))
    }

    @Test fun deleteConfirmationsNameWhatIsAndIsNotRemoved() {
        val local = personalDeleteMessage("Board review", hasAudio = true, sharedSession = false)
        assertTrue(local.contains("“Board review” and its audio file will be removed from this phone"))
        assertTrue(local.contains("shared with other apps are not affected"))
        assertFalse(local.contains("paired"))
        val paired = personalDeleteMessage("Board review", hasAudio = true, sharedSession = true)
        assertTrue(paired.contains("paired devices; they never received this audio"))
        val noAudio = personalDeleteMessage("Failed take", hasAudio = false, sharedSession = false)
        assertFalse(noAudio.contains("audio file"))
        assertFalse(noAudio.contains("other apps"))
        val pairedDraft = personalDeleteMessage("Planning", hasAudio = false, sharedSession = true)
        assertTrue(pairedDraft.endsWith("The shared meeting stays on your paired devices."))
        assertFalse(pairedDraft.contains("audio"))

        assertFalse(accountDeleteMessage(queued = false, uploaded = false).contains("upload"))
        assertTrue(accountDeleteMessage(queued = true, uploaded = false).contains("pending upload is cancelled"))
        assertTrue(accountDeleteMessage(queued = false, uploaded = true).contains("uploaded to your account is not affected"))
    }

    @Test fun orbitaSpanishDeleteConfirmationStatesTheSameFacts() {
        assertEquals("¿Eliminar esta reunión?", personalDeleteTitleEs(DRAFT))
        for (status in listOf(RECORDED, INTERRUPTED, FAILED)) assertEquals("¿Eliminar esta grabación?", personalDeleteTitleEs(status))
        val local = personalDeleteMessageEs("Revisión", hasAudio = true, sharedSession = false)
        assertTrue(local.startsWith("Se eliminarán de este teléfono «Revisión» y su archivo de audio. No se puede deshacer."))
        assertTrue(local.contains("otras apps no se modifican"))
        assertFalse(local.contains("vinculados"))
        assertFalse(local.contains("Mac"))
        val draft = personalDeleteMessageEs("Planificación", hasAudio = false, sharedSession = true)
        assertEquals("Se eliminará «Planificación» de este teléfono. No se puede deshacer. " +
            "La reunión compartida sigue en tus dispositivos vinculados.", draft)
        val pairedLocal = personalDeleteMessageEs("Revisión", hasAudio = true, sharedSession = true)
        assertTrue(pairedLocal.endsWith("nunca recibieron este audio."))
        assertEquals("Reunión eliminada de este teléfono.", personalDeletedMessageEs(DRAFT, deleted = true))
        assertEquals("Grabación eliminada de este teléfono.", personalDeletedMessageEs(INTERRUPTED, deleted = true))
        assertTrue(personalDeletedMessageEs(RECORDED, deleted = false).startsWith("No se pudo eliminar"))
    }

    @Test fun microphoneSettingsCopyIsAvailableInBothLanguages() {
        assertEquals("Open settings", MicrophoneSettingsCopy.ENGLISH.open)
        assertEquals("Abrir ajustes", MicrophoneSettingsCopy.SPANISH.open)
        assertTrue(MicrophoneSettingsCopy.SPANISH.message.contains("Permisos › Micrófono"))
    }

    @Test fun settingsDialogOnlyWhenAndroidWillNotAskAgain() {
        // Second denial ("don't ask again"), or a request Android answered without a dialog.
        assertTrue(shouldOfferPermissionSettings(granted = false, askedBefore = true, rationaleAfterDenial = false))
        // First denial: Android will still ask, so a brief message is enough.
        assertFalse(shouldOfferPermissionSettings(granted = false, askedBefore = false, rationaleAfterDenial = true))
        assertFalse(shouldOfferPermissionSettings(granted = false, askedBefore = true, rationaleAfterDenial = true))
        // A first request the user only dismissed also leaves the rationale false.
        assertFalse(shouldOfferPermissionSettings(granted = false, askedBefore = false, rationaleAfterDenial = false))
        assertFalse(shouldOfferPermissionSettings(granted = true, askedBefore = true, rationaleAfterDenial = false))
    }

    @Test fun notificationPermissionIsAskedOnceOnAndroid13AndLater() {
        assertTrue(shouldRequestNotificationPermission(sdkInt = 33, granted = false, askedBefore = false))
        assertTrue(shouldRequestNotificationPermission(sdkInt = 37, granted = false, askedBefore = false))
        assertFalse(shouldRequestNotificationPermission(sdkInt = 37, granted = false, askedBefore = true))
        assertFalse(shouldRequestNotificationPermission(sdkInt = 37, granted = true, askedBefore = false))
        assertFalse(shouldRequestNotificationPermission(sdkInt = 32, granted = false, askedBefore = false))
    }

    @Test fun recordingRequestBundlesNotificationsWithoutBlockingOnThem() {
        assertEquals(RecordingPermissionPlan(microphone = true, notifications = true),
            recordingPermissionPlan(36, microphoneGranted = false, notificationsGranted = false, notificationsAskedBefore = false))
        // Microphone granted, notifications never asked: ask notifications alone, then record whatever the answer.
        val notificationsOnly = recordingPermissionPlan(36, microphoneGranted = true, notificationsGranted = false,
            notificationsAskedBefore = false)
        assertEquals(RecordingPermissionPlan(microphone = false, notifications = true), notificationsOnly)
        assertTrue(notificationsOnly.needsRequest)
        // Already asked: start immediately.
        val none = recordingPermissionPlan(36, microphoneGranted = true, notificationsGranted = false, notificationsAskedBefore = true)
        assertFalse(none.needsRequest)
        assertEquals(RecordingPermissionPlan(microphone = true, notifications = false),
            recordingPermissionPlan(31, microphoneGranted = false, notificationsGranted = true, notificationsAskedBefore = false))
    }
}
