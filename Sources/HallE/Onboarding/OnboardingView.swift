import SwiftUI
import AppKit
import AVFoundation
import Speech
import UserNotifications

struct OnboardingView: View {
    @State private var language = AppLanguageStore.shared
    @State private var step = SetupReadiness.restoredStep(AppPreferences.onboardingStep)
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var meetingLanguage = AppPreferences.transcriptionLanguage
    @State private var engine = AppPreferences.transcriptionEngine
    @State private var localLocale: String?
    @State private var cloud = CloudFallbackPolicy.Availability()
    @State private var deepgramVerified = false
    @State private var speechmaticsVerified = false
    @State private var audioCheck = SetupAudioCheck()
    @State private var showingCloudSetup = false
    @State private var requestingPermission = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var startupError: String?
    @State private var reminderEnabled = false
    let onClose: (Bool) -> Void

    private func copy(_ en: String, _ es: String) -> String { PublicUICopy.text(en, es) }
    private var readiness: SetupReadiness {
        .init(microphoneGranted: micGranted, speechGranted: speechGranted,
              localModelAvailable: localLocale != nil, engine: engine, cloud: cloud,
              deepgramVerified: deepgramVerified, speechmaticsVerified: speechmaticsVerified)
    }
    private var stepTitles: [String] {
        [copy("Welcome", "Bienvenida"), copy("Microphone", "Micrófono"),
         copy("Transcription", "Transcripción"), copy("Your first meeting", "Tu primera reunión")]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 36, height: 36)
                Text("Hall-e").font(.title3.bold())
                Spacer()
                Text(copy("\(step + 1) of 4", "\(step + 1) de 4")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 30).padding(.top, 22)
            HStack(spacing: 8) {
                ForEach(0..<4) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.15)).frame(height: 4)
                        Text(stepTitles[index]).font(.caption2).foregroundStyle(index == step ? .primary : .secondary)
                    }
                }
            }.padding(.horizontal, 30).padding(.vertical, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { stepContent }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.bottom, 24)
            }
            Divider()
            HStack {
                Button(copy("Explore first", "Explorar primero")) { audioCheck.cancel(); onClose(false) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button(copy("Back", "Atrás")) { audioCheck.cancel(); step -= 1 } }
                Button(step == 3 ? copy("Open Hall-e", "Abrir Hall-e") : copy("Continue", "Continuar")) {
                    audioCheck.cancel()
                    if step == 3 { onClose(true) } else { step += 1 }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(audioCheck.isRunning || requestingPermission)
            }.padding(22)
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 600, idealHeight: 690)
        .environment(\.locale, language.locale)
        .onAppear { refreshPermissions() }
        .onChange(of: step) { _, value in AppPreferences.onboardingStep = value; refreshPermissions() }
        .onChange(of: meetingLanguage) { _, value in
            AppPreferences.transcriptionLanguage = value
            audioCheck.cancel()
            refreshPermissions()
        }
        .onChange(of: language.language) { _, _ in refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .onDisappear { audioCheck.cancel() }
        .sheet(isPresented: $showingCloudSetup, onDismiss: { refreshPermissions() }) {
            VStack(spacing: 0) {
                TranscriptionSettingsView(isOnboarding: true)
                Divider()
                HStack { Spacer(); Button(copy("Done", "Listo")) { showingCloudSetup = false }.keyboardShortcut(.defaultAction) }.padding()
            }.frame(width: 700, height: 620)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0:
            header("waveform", copy("Be in the meeting.\nKeep the conversation.", "Participa en la reunión.\nConserva la conversación."),
                   copy("Record, find what was said, and keep your notes together. Everything starts on your Mac.", "Graba, encuentra lo que se dijo y mantén tus notas juntas. Todo comienza en tu Mac."))
            Picker(copy("App language", "Idioma de la app"), selection: $language.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }.frame(maxWidth: 340)
            feature("person.crop.circle.badge.checkmark", copy("No account to create", "Sin crear una cuenta"), copy("No subscription or API key is needed for supported on-device transcription.", "La transcripción local compatible no necesita suscripción ni clave API."))
            feature("lock.shield", copy("Private by default", "Privado desde el inicio"), copy("Your recordings stay on your Mac. Cloud processing is optional and needs your permission.", "Tus grabaciones quedan en tu Mac. El procesamiento en la nube es opcional y requiere tu permiso."))
            feature("folder", copy("A workspace of your own", "Tu propio espacio de trabajo"), copy("No calendar, browser extension, or separate notes app needed to get started.", "No necesitas calendario, extensión del navegador ni otra app de notas para empezar."))
        case 1:
            header("mic", copy("Let Hall-e hear you", "Permite que Hall-e te escuche"), copy("You control when recording starts and stops. Hall-e shows a red recording indicator while it is listening.", "Tú decides cuándo comienza y termina la grabación. Hall-e muestra un indicador rojo mientras está escuchando."))
            statusRow(micGranted, copy("Microphone allowed", "Micrófono autorizado"), copy("Microphone permission needed", "Falta permiso de micrófono"))
            if !micGranted {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
                    Button(copy("Open microphone settings", "Abrir ajustes del micrófono")) { SystemSettingsOpener.openMicrophonePrivacy() }
                } else {
                    Button(copy("Allow microphone", "Permitir micrófono")) {
                        requestingPermission = true
                        Task { micGranted = await RecordingService.shared.requestMicAccess(); requestingPermission = false }
                    }.buttonStyle(.borderedProminent).disabled(requestingPermission)
                }
            }
            feature("headphones", copy("In person or on a call", "Presencial o por llamada"), copy("For an online meeting, choose your meeting app when you start recording so Hall-e can capture the other participants. Microphone-only capture may miss people you hear through headphones.", "Para una reunión en línea, elige la app de la llamada al iniciar la grabación para capturar a los demás participantes. Solo el micrófono puede omitir a quienes escuchas por audífonos."))
            Text(copy("Tell participants before recording. macOS asks separately before capturing another app’s audio.", "Avisa a los participantes antes de grabar. macOS pide un permiso adicional para capturar el audio de otra app.")).font(.callout).foregroundStyle(.secondary)
        case 2:
            header("text.bubble", copy("Words, without the setup work", "Palabras, sin complicaciones"), copy("Start with Apple’s on-device speech recognition. Choose the language you usually speak in meetings.", "Empieza con el reconocimiento de voz local de Apple. Elige el idioma que usas habitualmente en tus reuniones."))
            Picker(copy("Meeting language", "Idioma de las reuniones"), selection: $meetingLanguage) {
                ForEach(TranscriptionLanguagePreference.allCases) { value in
                    Text(value == .auto ? copy("Use my Mac’s language (local)", "Usar el idioma del Mac (local)") : value.displayName).tag(value)
                }
            }.disabled(audioCheck.isRunning)
            if readiness.usesLocalTranscription {
                statusRow(speechGranted, copy("Speech recognition allowed", "Reconocimiento de voz autorizado"), copy("Allow on-device speech recognition", "Autoriza el reconocimiento de voz local"))
                if !speechGranted {
                    Button(copy("Enable local transcription", "Activar transcripción local")) {
                        if SFSpeechRecognizer.authorizationStatus() == .denied || SFSpeechRecognizer.authorizationStatus() == .restricted {
                            SystemSettingsOpener.openSpeechPrivacy()
                        } else {
                            requestingPermission = true
                            Task { speechGranted = await LocalTranscriptionProvider.requestAuthorization(); requestingPermission = false; refreshPermissions() }
                        }
                    }.buttonStyle(.borderedProminent).disabled(requestingPermission)
                }
                if speechGranted {
                    statusRow(localLocale != nil, copy("Language available on this Mac", "Idioma disponible en este Mac"), copy("Language needs attention", "El idioma requiere atención"))
                    if localLocale == nil {
                        Text(copy("Open Keyboard settings, enable Dictation for your meeting language, then return and check again. If your Mac still cannot use it locally, you can connect a cloud provider or keep recording and transcribe later.", "Abre los ajustes de Teclado, activa Dictado para el idioma de tus reuniones y vuelve a revisar. Si tu Mac aún no puede usarlo localmente, conecta un proveedor en la nube o sigue grabando para transcribir después.")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(copy("Open Keyboard settings", "Abrir ajustes de Teclado")) { SystemSettingsOpener.openKeyboardSettings() }
                            Button(copy("Check again", "Volver a revisar")) { refreshPermissions() }
                        }
                    }
                }
            } else {
                statusRow(readiness.transcriptionReady, copy("Your existing cloud setup is connected", "Tu configuración de nube está conectada"), copy("Your selected provider needs setup", "Tu proveedor seleccionado necesita configuración"))
                Text(copy("Your existing provider choice is preserved. Local transcription is available from Settings → Transcription.", "Se conserva tu proveedor actual. Puedes elegir transcripción local en Ajustes → Transcripción.")).font(.caption).foregroundStyle(.secondary)
            }
            audioTest
            Divider()
            Button(copy("Optional: connect a cloud transcription account…", "Opcional: conectar una cuenta de transcripción en la nube…")) { showingCloudSetup = true }
                .buttonStyle(.link)
            Text(copy("Cloud providers can add anonymous speaker labels. They require your own key, internet, provider credit, and explicit permission. Local transcription does not identify speakers.", "Los proveedores en la nube pueden agregar etiquetas anónimas de hablantes. Requieren tu clave, internet, crédito del proveedor y permiso explícito. La transcripción local no identifica hablantes.")).font(.caption).foregroundStyle(.secondary)
        default:
            header(readiness.readyToMeet ? "checkmark.circle" : "waveform", readiness.readyToMeet ? copy("Your next meeting starts here", "Tu próxima reunión comienza aquí") : copy("Your workspace is ready", "Tu espacio de trabajo está listo"),
                   copy("Open Hall-e, choose Start recording, and focus on the conversation. Stop when you’re done; Hall-e keeps the recording and processes the transcript.", "Abre Hall-e, elige Iniciar grabación y concéntrate en la conversación. Detén la grabación al terminar; Hall-e conserva el audio y procesa la transcripción."))
            statusRow(micGranted, copy("Microphone ready", "Micrófono listo"), copy("Allow the microphone before recording", "Autoriza el micrófono antes de grabar"))
            statusRow(readiness.transcriptionReady, copy("Transcription configured", "Transcripción configurada"), copy("Transcription still needs setup; keep the audio and retry later", "Aún falta configurar la transcripción; conserva el audio y reintenta después"))
            feature("text.book.closed", copy("Find it in Meetings & recordings", "Encuéntralo en Reuniones y grabaciones"), copy("Play the audio, search the transcript, write notes, and export what you need.", "Reproduce el audio, busca en la transcripción, escribe notas y exporta lo que necesites."))
            Toggle(copy("Launch Hall-e when I log in", "Abrir Hall-e al iniciar sesión"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do { try LaunchAtLogin.set(enabled); startupError = nil }
                    catch { startupError = error.localizedDescription; launchAtLogin = LaunchAtLogin.isEnabled }
                }
            if let startupError { Text(startupError).font(.caption).foregroundStyle(.orange) }
            Button(reminderEnabled ? copy("Notifications enabled", "Notificaciones activadas") : copy("Enable meeting reminders (optional)", "Activar recordatorios de reuniones (opcional)")) {
                Task {
                    await NotificationScheduler.shared.requestAuthorizationIfNeeded()
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    reminderEnabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                }
            }.disabled(reminderEnabled)
            Text(copy("Connect calendars later in Settings → Accounts. Your projects, recordings, and provider settings are kept when updating Hall-e.", "Conecta calendarios después en Ajustes → Cuentas. Al actualizar Hall-e se conservan tus proyectos, grabaciones y proveedores.")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var audioTest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy("Try it before a meeting", "Pruébalo antes de una reunión")).font(.headline)
            Text(copy("Speak for 8 seconds. This disposable sample stays on your Mac and is deleted after the check.", "Habla durante 8 segundos. Esta muestra temporal queda en tu Mac y se elimina al terminar la prueba.")).font(.caption).foregroundStyle(.secondary)
            if audioCheck.phase == .recording {
                HStack {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text(copy("Speak now · \(audioCheck.secondsRemaining)s", "Habla ahora · \(audioCheck.secondsRemaining)s"))
                    ProgressView(value: audioCheck.level).frame(maxWidth: 180)
                }.accessibilityLabel(copy("Recording microphone test", "Grabando prueba de micrófono"))
            } else if audioCheck.phase == .transcribing {
                HStack { ProgressView().controlSize(.small); Text(copy("Transcribing on your Mac…", "Transcribiendo en tu Mac…")) }
            } else if audioCheck.phase == .completed {
                statusRow(true, audioCheck.text.isEmpty ? copy("Microphone check passed", "Prueba de micrófono completada") : copy("Recording and local transcription work", "La grabación y transcripción local funcionan"), "")
                if !audioCheck.text.isEmpty { Text(audioCheck.text).font(.callout).textSelection(.enabled) }
            } else if let error = audioCheck.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if audioCheck.isRunning {
                Button(copy("Cancel check", "Cancelar prueba")) { audioCheck.cancel() }
            } else {
                Button(readiness.usesLocalTranscription && readiness.transcriptionReady ? copy("Test recording & transcription", "Probar grabación y transcripción") : copy("Test microphone", "Probar micrófono")) {
                    audioCheck.start(language: meetingLanguage.sfSpeechCode,
                                     transcribe: readiness.usesLocalTranscription && readiness.transcriptionReady)
                }.disabled(!micGranted || RecordingService.shared.isRecording)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }

    private func header(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(title).font(.system(size: 29, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func statusRow(_ ready: Bool, _ success: String, _ pending: String) -> some View {
        Label(ready ? success : pending, systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(ready ? Color.green : Color.secondary).font(.callout)
    }
    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
        engine = AppPreferences.transcriptionEngine
        localLocale = speechGranted ? LocalTranscriptionProvider.firstAvailableRecognizer(language: meetingLanguage.sfSpeechCode)?.1 : nil
        cloud = .init(deepgramConfigured: KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount),
                      deepgramConsented: AppPreferences.allowCloudAudioTranscription,
                      speechmaticsConfigured: AppPreferences.speechmaticsRegion?.isSupported == true && KeychainStore.exists(account: KeychainStore.speechmaticsTranscriptionAccount),
                      speechmaticsConsented: AppPreferences.allowSpeechmaticsAudioTranscription)
        deepgramVerified = CloudCredentialValidation.savedKeyIsVerified(target: .deepgram)
        speechmaticsVerified = AppPreferences.speechmaticsRegion.map {
            CloudCredentialValidation.savedKeyIsVerified(target: .speechmatics($0))
        } ?? false
    }
}
