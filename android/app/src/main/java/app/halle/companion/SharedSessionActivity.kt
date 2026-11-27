package app.halle.companion

import android.app.Activity
import android.app.AlertDialog
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.google.zxing.integration.android.IntentIntegrator
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Visible, user-driven pairing and metadata sharing controls. No background path starts capture. */
class SharedSessionActivity : Activity() {
    companion object {
        const val EXTRA_SCAN_ON_LAUNCH = "app.halle.companion.EXTRA_SCAN_QR_ON_LAUNCH"
    }

    private lateinit var client: SharedSessionClient
    private lateinit var content: LinearLayout
    private lateinit var inviteInput: EditText
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var closed = false
    private var busy = false
    private val buttonStatesBeforeBusy = mutableMapOf<Button, Boolean>()
    private var lastState: SharedWorkspaceState? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val poll = object : Runnable {
        override fun run() {
            if (closed || !client.paired()) return
            if (busy) {
                mainHandler.postDelayed(this, 500L)
                return
            }
            runNetwork(
                operation = { client.state() },
                onSuccess = { state ->
                    lastState = state
                    render()
                    val lease = state.activeLease
                    val delay = if (lease?.handoffRequestedDeviceId != null) 2_000L else 10_000L
                    mainHandler.postDelayed(this, delay)
                },
                onFailure = { mainHandler.postDelayed(this, 2_000L) },
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Staging builds must never reach the production pairing coordinator; MainActivity hides the entry point.
        if (BuildConfig.STAGING) { finish(); return }
        client = SharedSessionClient(this)
        render()
        val scanRequested = intent.getBooleanExtra(EXTRA_SCAN_ON_LAUNCH, false)
        intent.removeExtra(EXTRA_SCAN_ON_LAUNCH)
        if (savedInstanceState == null && scanRequested &&
            callingActivity == ComponentName(this, MainActivity::class.java)) {
            mainHandler.post { if (!closed) scanPairingCode() }
        }
        if (client.paired()) mainHandler.post(poll)
    }

    override fun onDestroy() {
        closed = true
        mainHandler.removeCallbacks(poll)
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun render() {
        val scroll = ScrollView(this).apply { setBackgroundColor(0xff080e10.toInt()) }
        content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(28))
        }
        scroll.addView(content)
        setContentView(scroll)
        content.addView(label("Shared sessions", 25, 0xff1f322e.toInt(), true))
        content.addView(label(
            "Encrypted meeting details can be shared across your Hall-e devices. Audio stays on the phone that records; this coordinator never receives audio or starts a microphone.",
            14, 0xff52675e.toInt(),
        ))
        content.addView(space(14))

        if (!client.paired()) {
            content.addView(button("Escanear QR de un Mac") { scanPairingCode() })
            content.addView(space(8))
            content.addView(button("Create shared workspace") {
                runNetwork({ client.createWorkspace(android.os.Build.MODEL ?: "Android device") }) { link ->
                    showInvitation(link)
                    lastState = null
                    render()
                    refreshStateAndPoll()
                }
            })
            content.addView(space(12))
            content.addView(label("Join with an invitation", 17, 0xff263a32.toInt(), true))
            inviteInput = EditText(this).apply {
                hint = "Paste a Hall-e invitation link or pairing code"
                minLines = 2
                gravity = Gravity.TOP
                setText(intent?.dataString.orEmpty())
            }
            content.addView(inviteInput)
            content.addView(button("Review invitation") { reviewInvitation() })
            content.addView(space(8))
            content.addView(label("An unpaired phone joins when you scan a valid QR. Pasted invitations are reviewed before joining. Use invitations only from a workspace you trust.", 12, 0xff65776f.toInt()))
            return
        }

        val state = lastState
        content.addView(label("This device is paired", 17, 0xff286b4d.toInt(), true))
        content.addView(button("Escanear QR para cambiar de espacio") { scanPairingCode() })
        content.addView(button("Refresh shared workspace") {
            runNetwork({ client.state() }) { lastState = it; render() }
        })
        if (state == null) {
            content.addView(label("Loading workspace…", 13, 0xff65776f.toInt()))
            return
        }
        if (state.ownerDeviceId == client.currentDeviceId()) {
            content.addView(button("Share a new device invitation") {
                AlertDialog.Builder(this).setTitle("Create a new invitation?")
                    .setMessage("This invalidates any earlier invitation and expires in 10 minutes.")
                    .setPositiveButton("Create invitation") { _, _ ->
                        runNetwork({ client.createInvitationLink() }) { showInvitation(it) }
                    }.setNegativeButton("Cancel", null).show()
            })
        }
        content.addView(space(8))
        content.addView(label("Devices · " + state.devices.count { it.revokedAtMs == null }, 15, 0xff263a32.toInt(), true))
        val isOwner = state.ownerDeviceId == client.currentDeviceId()
        state.devices.filter { it.revokedAtMs == null }.forEach { device ->
            content.addView(label(device.name + if (device.id == state.ownerDeviceId) " · Owner" else "", 13, 0xff52675e.toInt()))
            if (isOwner && device.id != client.currentDeviceId()) {
                content.addView(button("Revoke " + device.name) {
                    AlertDialog.Builder(this).setTitle("Remove this device?")
                        .setMessage("It will immediately lose access to shared sessions.")
                        .setPositiveButton("Revoke") { _, _ ->
                            runNetwork({ client.revokeDevice(device.id) }) {
                                toast("Device access revoked.")
                                refreshState()
                            }
                        }.setNegativeButton("Cancel", null).show()
                })
            }
        }
        content.addView(space(10))
        content.addView(label("Shared meetings · " + state.sessions.size, 15, 0xff263a32.toInt(), true))
        state.sessions.forEach { session ->
            content.addView(label(
                (session.title ?: "Meeting details unavailable") +
                    (session.projectName?.let { " · " + it } ?: "") +
                    if (session.decryptionFailed) " · Could not decrypt" else "",
                14, if (session.decryptionFailed) 0xff9b4635.toInt() else 0xff263a32.toInt(), true,
            ))
            if (!session.decryptionFailed) {
                content.addView(button("Update project details") { chooseProject(session) })
                content.addView(button("Prepare to record this meeting on this phone") {
                    runCatching {
                        val meetings = MobileMeetingStore(this)
                        meetings.draftForSharedSession(session.id) ?: meetings.createDraft(
                            title = session.title ?: "Meeting",
                            projectName = session.projectName,
                            scheduledStartAtMs = session.startAtMs,
                            scheduledEndAtMs = session.endAtMs,
                            sharedSessionId = session.id,
                        )
                    }.onSuccess { draft ->
                        startActivity(Intent(this, MainActivity::class.java)
                            .putExtra(MainActivity.EXTRA_START_RECORDING, draft.id))
                    }.onFailure { toast(it.message ?: "Could not prepare this meeting on this phone.") }
                })
            }
        }
        content.addView(space(10))
        content.addView(label(
            when {
                state.activeLease == null -> "No phone currently holds the recording lease."
                state.activeLease.handoffRequestedDeviceId != null ->
                    "A handoff is waiting. The current recorder will stop locally before this phone can claim the lease."
                else -> "Recording lease held by " + (state.devices.firstOrNull { it.id == state.activeLease.deviceId }?.name ?: "another device") + "."
            },
            13, 0xff52675e.toInt(),
        ))
        val activeLease = state.activeLease
        if (activeLease != null && activeLease.deviceId != currentDeviceId(state)) {
            val holderName = state.devices.firstOrNull { it.id == activeLease.deviceId }?.name ?: "another device"
            content.addView(button(
                if (activeLease.handoffRequestedDeviceId == currentDeviceId(state)) "Handoff request sent · waiting for " + holderName
                else "Request handoff from " + holderName,
            ) {
                runNetwork({ client.requestHandoffToThisDevice() }) {
                    toast("Handoff requested. The current recorder will stop automatically when it receives the request.")
                    lastState = null
                    refreshState()
                }
            }.apply { isEnabled = activeLease.handoffRequestedDeviceId != currentDeviceId(state) })
        }
        content.addView(space(10))
        val localDrafts = MobileMeetingStore(this).list().filter { it.status == MobileMeetingStatus.DRAFT }
        content.addView(label("Local drafts ready to share · " + localDrafts.size, 15, 0xff263a32.toInt(), true))
        localDrafts.forEach { meeting ->
            content.addView(button("Share “" + meeting.title + "”") {
                try {
                    runNetwork({ client.createSession(meeting) }) {
                        toast("Encrypted meeting details shared.")
                        refreshState()
                    }
                } catch (error: Exception) {
                    toast(error.message ?: "Could not share this meeting.")
                }
            })
        }
        content.addView(space(12))
        val activeRecording = MobileMeetingStore(this).activeRecording()
        val pendingRecording = SharedSessionClient.recordingPreparationActive()
        val otherActiveDevices = state.devices.count { it.revokedAtMs == null && it.id != client.currentDeviceId() }
        val ownerMustRevokeFirst = isOwner && otherActiveDevices > 0
        content.addView(button(
            if (activeRecording != null) "Stop this phone’s recording before leaving"
            else if (pendingRecording) "Wait for recording preparation to finish"
            else if (ownerMustRevokeFirst) "Revoke other devices before owner leaves"
            else "Leave shared workspace",
        ) {
            AlertDialog.Builder(this).setTitle("Leave shared workspace?")
                .setMessage("This removes this device's shared access. Local meetings and recordings stay on this phone.")
                .setPositiveButton("Leave") { _, _ ->
                    runNetwork({ client.leaveWorkspace() }) {
                        lastState = null
                        render()
                        toast("This device left the shared workspace.")
                    }
                }.setNegativeButton("Cancel", null).show()
        }.apply { isEnabled = activeRecording == null && !pendingRecording && !busy && !ownerMustRevokeFirst })
    }

    private fun reviewInvitation() {
        val raw = inviteInput.text.toString().trim()
        val parsed = runCatching { client.parsePairingInput(raw) }.getOrElse {
            toast("That invitation is invalid or uses an unsupported coordinator.")
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Join shared workspace?")
            .setMessage("This will pair this phone with workspace " + parsed.workspaceId +
                ". Shared meeting titles and project details will be encrypted between devices. Continue only if you trust this invitation.")
            .setPositiveButton("Join") { _, _ ->
                runNetwork({ client.joinWorkspace(raw, android.os.Build.MODEL ?: "Android device") }) {
                    lastState = null
                    render()
                    refreshStateAndPoll()
                }
            }.setNegativeButton("Cancel", null).show()
    }

    private fun scanPairingCode() {
        if (busy) return
        val options = IntentIntegrator(this)
            .setDesiredBarcodeFormats(IntentIntegrator.QR_CODE)
            .setPrompt("Escanea el QR de invitación de Hall-e en tu Mac")
            .setBeepEnabled(false)
            .setBarcodeImageEnabled(false)
            // The manifest owns portrait orientation. ZXing must not lock the
            // device's previous display rotation over that explicit choice.
            .setOrientationLocked(false)
        options.initiateScan()
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val result = IntentIntegrator.parseActivityResult(requestCode, resultCode, data) ?: return
        val scanned = result.contents ?: run {
            toast("Se canceló el escaneo. No se cambió la vinculación.")
            return
        }
        val parsed = runCatching { client.parsePairingInput(scanned) }.getOrElse {
            toast("El QR no es una invitación de Hall-e válida para este servicio.")
            return
        }
        val storedCredentialsExist = hasStoredCredentials()
        if (client.paired() || storedCredentialsExist) {
            val previousWorkspace = client.currentWorkspaceId()
            val target = parsed.workspaceId
            AlertDialog.Builder(this)
                .setTitle("¿Cambiar la vinculación de este teléfono?")
                .setMessage(if (previousWorkspace != null) {
                    "Se vinculará con el espacio $target. La vinculación guardada con $previousWorkspace se reemplazará solo si la nueva invitación se acepta."
                } else {
                    "Hay credenciales guardadas que no se pueden verificar. Si la invitación se acepta, se reemplazarán por las del espacio $target."
                })
                .setPositiveButton("Vincular") { _, _ -> joinScannedInvitation(scanned) }
                .setNegativeButton("Cancelar", null)
                .show()
        } else {
            // Scanning an invite on an unpaired phone is the user's explicit instruction to link it.
            joinScannedInvitation(scanned)
        }
    }

    private fun joinScannedInvitation(invitation: String) {
        if (busy) {
            mainHandler.postDelayed({ if (!closed) joinScannedInvitation(invitation) }, 400L)
            return
        }
        runNetwork(
            operation = { client.joinWorkspace(invitation, android.os.Build.MODEL ?: "Teléfono Android") },
            onSuccess = {
                lastState = null
                render()
                toast("Teléfono vinculado al espacio compartido.")
                refreshStateAndPoll()
            },
            errorMessage = ::pairingFailureMessage,
        )
    }

    private fun pairingFailureMessage(error: Throwable): String = when {
        error is WorkspaceChangeBlockedException -> error.message ?: "Termina la grabación antes de cambiar de espacio."
        error is SharedCoordinatorException && error.code in setOf("invite_invalid", "invite_expired") ->
            "La invitación venció o ya se usó. Pide un QR nuevo en tu Mac."
        error is SharedCoordinatorException && error.code == "rate_limited" ->
            "Demasiados intentos. Espera un momento y vuelve a escanear."
        else -> "No se pudo vincular el teléfono. Revisa la conexión y vuelve a intentarlo."
    }

    private fun hasStoredCredentials(): Boolean = getSharedPreferences("shared-session-credentials", MODE_PRIVATE)
        .contains("credentials")

    private fun showInvitation(link: String) {
        AlertDialog.Builder(this).setTitle("Workspace invitation")
            .setMessage("This single-use invitation contains workspace access and its encryption key. Share it only with a device you trust.\n\n" + link)
            .setPositiveButton("Share") { _, _ ->
                val share = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, link)
                startActivity(Intent.createChooser(share, "Share Hall-e invitation"))
            }.setNeutralButton("Done", null).show()
    }

    private fun chooseProject(session: SharedSession) {
        val projects = LocalStore(this).projects()
        val choices = projects + listOf("Unclassified")
        AlertDialog.Builder(this).setTitle("Project for " + (session.title ?: "meeting"))
            .setItems(choices.toTypedArray()) { _, index ->
                val project = projects.getOrNull(index)
                runNetwork({ client.updateSessionProject(session.id, project, session.revision) }) {
                    toast("Encrypted project details updated.")
                    refreshState()
                }
            }.setNegativeButton("Cancel", null).show()
    }

    private fun currentDeviceId(state: SharedWorkspaceState): String? = client.currentDeviceId()

    private fun refreshState() {
        runNetwork({ client.state() }) { lastState = it; render() }
    }

    private fun refreshStateAndPoll() {
        mainHandler.removeCallbacks(poll)
        runNetwork(
            operation = { client.state() },
            onSuccess = { state ->
                lastState = state
                render()
                val delay = if (state.activeLease?.handoffRequestedDeviceId != null) 2_000L else 10_000L
                mainHandler.postDelayed(poll, delay)
            },
            onFailure = { mainHandler.postDelayed(poll, 2_000L) },
        )
    }

    private fun <T> runNetwork(
        operation: () -> T,
        onFailure: ((Throwable) -> Unit)? = null,
        errorMessage: (Throwable) -> String = { it.message ?: "Could not reach the shared-session coordinator." },
        onSuccess: (T) -> Unit,
    ) {
        if (busy) return
        busy = true
        setControlsEnabled(false)
        executor.execute {
            val result = runCatching(operation)
            mainHandler.post {
                if (closed) return@post
                busy = false
                result.onSuccess(onSuccess).onFailure { error ->
                    toast(errorMessage(error))
                    onFailure?.invoke(error)
                }
                setControlsEnabled(true)
            }
        }
    }

    private fun setControlsEnabled(enabled: Boolean) {
        if (enabled) {
            buttonStatesBeforeBusy.forEach { (button, wasEnabled) -> button.isEnabled = wasEnabled }
            buttonStatesBeforeBusy.clear()
            return
        }
        buttonStatesBeforeBusy.clear()
        fun visit(view: android.view.View) {
            if (view is Button) {
                buttonStatesBeforeBusy[view] = view.isEnabled
                view.isEnabled = false
            }
            if (view is android.view.ViewGroup) {
                for (index in 0 until view.childCount) visit(view.getChildAt(index))
            }
        }
        visit(content)
    }

    private fun button(title: String, action: () -> Unit) = Button(this).apply {
        text = title
        setOnClickListener { action() }
    }

    private fun label(value: String, size: Int, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = value
        textSize = size.toFloat()
        setTextColor(if (size >= 17 || bold) 0xffe4e9d9.toInt() else 0xffa4b7b1.toInt())
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(dp(2), dp(6), dp(2), dp(6))
    }

    private fun space(height: Int) = TextView(this).apply {
        layoutParams = LinearLayout.LayoutParams(1, dp(height))
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun toast(value: String) = Toast.makeText(this, value, Toast.LENGTH_LONG).show()
}
