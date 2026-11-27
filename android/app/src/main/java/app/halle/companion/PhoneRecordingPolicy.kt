package app.halle.companion

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast

/** Actions a phone recording can offer. The activities render them; the decisions stay pure and unit-tested. */
internal enum class PhoneRecordingAction { PLAY, SHARE_AUDIO, SHARE_PARTIAL_FILE, RETRY_UPLOAD, CANCEL_UPLOAD, STOP, SEND, DELETE }

internal fun isRecordingInProgress(status: MobileMeetingStatus) =
    status == MobileMeetingStatus.STARTING || status == MobileMeetingStatus.RECORDING

/** A recorder may still be writing the file, so a recording in progress must be stopped before it is deleted. */
internal fun canDeleteRecording(status: MobileMeetingStatus) = !isRecordingInProgress(status)

/**
 * Home-screen library ("Meetings on this phone"). [playable] means [MobileMeetingStore.playbackUri] resolved a finalized
 * `.m4a`; [partialFile] means only the raw `.m4a.partial` of an interrupted recorder exists. A draft (saved without
 * recording) keeps its Record action and can also be deleted, so a mistaken meeting is never stuck on the phone.
 */
internal fun personalRecordingActions(status: MobileMeetingStatus, playable: Boolean, partialFile: Boolean): List<PhoneRecordingAction> =
    buildList {
        val finished = status == MobileMeetingStatus.RECORDED || status == MobileMeetingStatus.INTERRUPTED
        if (finished && playable) { add(PhoneRecordingAction.PLAY); add(PhoneRecordingAction.SHARE_AUDIO) }
        if (status == MobileMeetingStatus.INTERRUPTED && partialFile) add(PhoneRecordingAction.SHARE_PARTIAL_FILE)
        if (finished || status == MobileMeetingStatus.FAILED || status == MobileMeetingStatus.DRAFT) add(PhoneRecordingAction.DELETE)
    }

/**
 * A phone recording listed under a live account meeting. [playable] is [MobileMeetingStore.completedAudio] != null:
 * a finalized `.m4a`, also for an interrupted recorder that MediaRecorder could still stop. A raw `.m4a.partial` left
 * by a killed process has no MPEG-4 index (MediaRecorder writes it at stop), so it is neither played nor uploaded.
 * Interrupted and failed recordings can always be deleted, so they are never a dead end.
 */
internal fun accountRecordingActions(
    status: MobileMeetingStatus,
    playable: Boolean,
    queued: Boolean,
    uploadProblem: Boolean,
    uploaded: Boolean,
): List<PhoneRecordingAction> = buildList {
    if (playable) add(PhoneRecordingAction.PLAY)
    if (uploadProblem) { add(PhoneRecordingAction.RETRY_UPLOAD); add(PhoneRecordingAction.CANCEL_UPLOAD) }
    if (isRecordingInProgress(status)) add(PhoneRecordingAction.STOP)
    else if (playable && !queued && !uploaded) add(PhoneRecordingAction.SEND)
    if (status == MobileMeetingStatus.INTERRUPTED || status == MobileMeetingStatus.FAILED) add(PhoneRecordingAction.DELETE)
}

/** Confirmation text for deleting a recording, or a meeting saved without one, from the home-screen library. */
internal fun personalDeleteMessage(title: String, hasAudio: Boolean, sharedSession: Boolean): String = buildString {
    append(if (hasAudio) "“$title” and its audio file will be removed from this phone. This cannot be undone."
        else "“$title” will be removed from this phone. This cannot be undone.")
    if (hasAudio) append(" Copies you already shared with other apps are not affected.")
    if (sharedSession) append(if (hasAudio) " The shared meeting stays on your paired devices; they never received this audio."
        else " The shared meeting stays on your paired devices.")
}

/** Confirmation text for deleting an interrupted or failed phone recording of an account meeting. */
internal fun accountDeleteMessage(queued: Boolean, uploaded: Boolean): String = buildString {
    append("This recording and its audio file will be removed from this phone. This cannot be undone.")
    if (queued) append(" Its pending upload is cancelled.")
    if (uploaded) append(" The copy uploaded to your account is not affected.")
}

/**
 * After a denied runtime permission: true when Android will not show its dialog again, so only the app's settings page
 * can grant it. Android reports that indirectly: the rationale flag is false after a denial although the app asked
 * before ([askedBefore]: a stored flag, or a rationale flag that was true before this request). A first request the user
 * merely dismissed also leaves the rationale false, which is why [askedBefore] is required.
 */
internal fun shouldOfferPermissionSettings(granted: Boolean, askedBefore: Boolean, rationaleAfterDenial: Boolean): Boolean =
    !granted && askedBefore && !rationaleAfterDenial

/**
 * Android 13+ hides a foreground service notification (and its Stop action) without POST_NOTIFICATIONS. Ask once
 * before recording; the answer never blocks recording, and a remembered request is not repeated.
 */
internal fun shouldRequestNotificationPermission(sdkInt: Int, granted: Boolean, askedBefore: Boolean): Boolean =
    sdkInt >= 33 && !granted && !askedBefore

/** Which permissions to request before recording. Both false: start immediately. */
internal data class RecordingPermissionPlan(val microphone: Boolean, val notifications: Boolean) {
    val needsRequest: Boolean get() = microphone || notifications
}

internal fun recordingPermissionPlan(sdkInt: Int, microphoneGranted: Boolean, notificationsGranted: Boolean,
                                     notificationsAskedBefore: Boolean) = RecordingPermissionPlan(
    microphone = !microphoneGranted,
    notifications = shouldRequestNotificationPermission(sdkInt, notificationsGranted, notificationsAskedBefore),
)

/** Remembers which runtime permissions this app has requested, so prompts are not repeated or misread. */
internal class PermissionPrompts(context: Context) {
    private val prefs = context.getSharedPreferences("permission-prompts", Context.MODE_PRIVATE)
    fun asked(permission: String): Boolean = prefs.getBoolean(permission, false)
    fun markAsked(permission: String) { prefs.edit().putBoolean(permission, true).apply() }
}

/** Runtime permissions to request before recording; empty means start now. */
internal class RecordingPermissionRequest(val permissions: Array<String>, val microphoneAskedBefore: Boolean)

/** Plans the pre-recording request and remembers it, so notifications are asked once and a later denial can be read. */
internal fun Activity.prepareRecordingPermissions(): RecordingPermissionRequest {
    val prompts = PermissionPrompts(this)
    val granted = { permission: String -> checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED }
    val plan = recordingPermissionPlan(Build.VERSION.SDK_INT, granted(Manifest.permission.RECORD_AUDIO),
        Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS),
        prompts.asked(Manifest.permission.POST_NOTIFICATIONS))
    val microphoneAskedBefore = plan.microphone && (prompts.asked(Manifest.permission.RECORD_AUDIO) ||
        shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO))
    val permissions = buildList {
        if (plan.microphone) add(Manifest.permission.RECORD_AUDIO)
        if (plan.notifications) add(Manifest.permission.POST_NOTIFICATIONS)
    }
    permissions.forEach(prompts::markAsked)
    return RecordingPermissionRequest(permissions.toTypedArray(), microphoneAskedBefore)
}

/** After a request that included RECORD_AUDIO was denied: whether only the settings page can still grant it. */
internal fun Activity.microphoneNeedsSettings(askedBefore: Boolean): Boolean = shouldOfferPermissionSettings(
    granted = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
    askedBefore = askedBefore,
    rationaleAfterDenial = shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO),
)

/** Explains how to allow the microphone once Android will no longer ask, with a shortcut to this app's settings. */
internal fun Activity.showMicrophoneSettingsDialog() {
    if (isFinishing || isDestroyed) return
    AlertDialog.Builder(this).setTitle("Allow microphone access")
        .setMessage("Android will not ask again for the microphone. To record with this phone, open Hall-e’s settings, " +
            "tap Permissions › Microphone and choose “Allow only while using the app”.")
        .setNegativeButton("Not now", null)
        .setPositiveButton("Open settings") { _, _ -> openAppSettings() }
        .show()
}

internal fun Activity.openAppSettings() {
    runCatching {
        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
    }.onFailure { Toast.makeText(this, "Open Android Settings › Apps › Hall-e to allow the microphone.", Toast.LENGTH_LONG).show() }
}
