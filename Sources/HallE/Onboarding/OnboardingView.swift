import SwiftUI
import AppKit
import AVFoundation
import Speech

struct OnboardingView: View {
    @State private var language = AppLanguageStore.shared
    @State private var step = 0
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Environment(\.scenePhase) private var scenePhase
    let onClose: (Bool) -> Void

    private func copy(_ en: String, _ es: String) -> String { PublicUICopy.text(en, es) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<5) { index in
                    Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.2)).frame(height: 4)
                }
            }.padding(20)
            if step == 2 || step == 3 {
                VStack(alignment: .leading, spacing: 12) { stepContent }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { stepContent }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 44).padding(.bottom, 20)
                }
            }
            Divider()
            HStack {
                Button(copy("Set up later", "Configurar después")) { onClose(false) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if step > 0 { Button(copy("Back", "Atrás")) { step -= 1 } }
                Button(step == 4 ? copy("Open Hall-e", "Abrir Hall-e") : copy("Continue", "Continuar")) {
                    if step == 4 { onClose(true) } else { step += 1 }
                }.buttonStyle(.borderedProminent)
            }.padding(20)
        }
        .frame(width: 720, height: 680)
        .environment(\.locale, language.locale)
        .onChange(of: step) { _, value in AppPreferences.onboardingStep = value }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshPermissions() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case 0:
            header("waveform", copy("Welcome to Hall-e", "Bienvenido a Hall-e"), copy("Start with recording and transcription. Connect other tools whenever you need them.", "Empieza grabando y transcribiendo. Conecta otras herramientas cuando las necesites."))
            Picker(L10n.text("settings.language"), selection: $language.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }.frame(maxWidth: 320)
            Label(copy("No calendar, notes app, or AI account required.", "No necesitas calendario, app de notas ni cuenta de IA."), systemImage: "checkmark.circle")
            Label(copy("Cloud transcription uploads audio only with your permission.", "La transcripción en la nube envía audio solo con tu permiso."), systemImage: "hand.raised")
        case 1:
            header("mic", copy("Enable your microphone", "Activa el micrófono"), copy("Start a recording from the workspace. A red indicator shows when recording is active.", "Inicia una grabación desde el espacio de trabajo. Un indicador rojo muestra cuándo estás grabando."))
            Label(micGranted ? copy("Microphone allowed", "Micrófono autorizado") : copy("Microphone permission needed to record", "Necesitas permiso de micrófono para grabar"), systemImage: micGranted ? "checkmark.circle.fill" : "mic.slash")
            if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
                Button(copy("Open microphone privacy settings…", "Abrir privacidad del micrófono…")) { SystemSettingsOpener.openMicrophonePrivacy() }
            } else {
                Button(copy("Allow microphone", "Permitir micrófono")) { Task { micGranted = await RecordingService.shared.requestMicAccess() } }.disabled(micGranted)
            }
            Text(copy("System audio permission is requested when you choose to capture a supported app.", "El permiso de audio del sistema se solicita al capturar una app compatible.")).foregroundStyle(.secondary)
        case 2:
            header("text.bubble", copy("Connect transcription", "Conecta la transcripción"), copy("Use your own free-trial account. Open a provider below, create an API key, and paste it into Hall-e. One provider is enough to start; we recommend both for fallback.", "Usa tu propia cuenta de prueba gratuita. Abre un proveedor, crea una clave API y pégala en Hall-e. Uno basta para empezar; recomendamos ambos para tener respaldo."))
            TranscriptionSettingsView(isOnboarding: true)
                .frame(maxHeight: .infinity)
            Text(copy("You can also record now and set up transcription later. Your audio stays on your Mac until you enable a provider.", "También puedes grabar ahora y configurar la transcripción después. El audio permanece en tu Mac hasta que actives un proveedor."))
                .font(.caption).foregroundStyle(.secondary)
        case 3:
            header("calendar", copy("Connect your meeting accounts", "Conecta tus cuentas de reuniones"), copy("Bring in Google, Outlook/Microsoft 365, and other calendars from your Mac, including Teams invitations.", "Conecta Google, Outlook/Microsoft 365 y otros calendarios de tu Mac, incluidas invitaciones de Teams."))
            AccountsSettingsView()
                .frame(maxHeight: .infinity)
        default:
            header("checkmark.circle", copy("Start using Hall-e", "Empieza a usar Hall-e"), copy("Use Start recording in the workspace. Find audio and transcripts under Meetings & recordings → Recordings.", "Usa Iniciar grabación en el espacio de trabajo. Encuentra audio y transcripciones en Reuniones y grabaciones → Grabaciones."))
            if !micGranted { Text(copy("Microphone access is still needed before recording.", "Aún necesitas acceso al micrófono para grabar.")).foregroundStyle(.orange) }
            Text(copy("Optional: connect a calendar, choose a notes folder, or configure AI in Settings. No separate notes app is required.", "Opcional: conecta un calendario, elige una carpeta de notas o configura IA en Ajustes. No necesitas otra app de notas."))
            Link(copy("Star Hall-e on GitHub", "Dale una estrella a Hall-e en GitHub"), destination: CommunityLinks.github)
            Link(copy("Coffee & support information", "Información para apoyar e invitar un café"), destination: CommunityLinks.support)
        }
    }

    private func header(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text(title).font(.largeTitle.weight(.semibold))
            Text(detail).font(.title3).foregroundStyle(.secondary)
        }
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
