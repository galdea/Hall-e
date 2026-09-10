import SwiftUI
import Speech
import AppKit

struct TranscriptionSettingsView: View {
    var isOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var engine = AppPreferences.transcriptionEngine
    @State private var language = AppPreferences.transcriptionLanguage
    @State private var speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var deepgramKey = ""
    @State private var deepgramKeyStored = KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount)
    @State private var speechmaticsKey = ""
    @State private var speechmaticsKeyStored = KeychainStore.exists(account: KeychainStore.speechmaticsTranscriptionAccount)
    @State private var speechmaticsRegion = AppPreferences.speechmaticsRegion
    @State private var speechmaticsTrainingOff = AppPreferences.speechmaticsModelTrainingConfirmedOff
    @State private var speechmaticsAudioEnabled = AppPreferences.allowSpeechmaticsAudioTranscription
    @State private var cloudAudioEnabled = AppPreferences.allowCloudAudioTranscription
    @State private var cloudReportsEnabled = AppPreferences.allowCloudTranscriptReports
    @State private var monthlyLimit = AppPreferences.deepgramMonthlyLimitUSD
    @State private var cloudConfirmation: CloudConfirmation?
    @State private var keyError: String?
    @State private var cloudExpanded = false
    @State private var speechLocale: String?
    @State private var deepgramVerified = false
    @State private var speechmaticsVerified = false
    @State private var checkingTarget: CloudCredentialTarget?
    @State private var credentialCheckTask: Task<Void, Never>?
    @State private var credentialCheckID: UUID?

    private enum CloudConfirmation: String, Identifiable {
        case deepgramAudio, speechmaticsAudio, reports
        var id: String { rawValue }
    }

    private var speechLanguage: String { language.sfSpeechCode }
    private func copy(_ en: String, _ es: String) -> String { PublicUICopy.text(en, es) }

    var body: some View {
        Form {
            Section(copy("Your meetings, on your Mac", "Tus reuniones, en tu Mac")) {
                Text(copy("Recording, notes, and supported on-device transcription need no account or API key. Cloud transcription is optional and uses your own provider account with your permission.", "Las grabaciones, las notas y la transcripción local compatible no necesitan cuenta ni clave API. La transcripción en la nube es opcional y usa tu propia cuenta, con tu autorización."))
                Text(copy("Local speech requires macOS permission and an available language model. If it is unavailable, you can keep recording and transcribe later, or connect a cloud provider.", "La transcripción local requiere permiso de macOS y un modelo de idioma disponible. Si no está disponible, puedes grabar y transcribir después, o conectar un proveedor en la nube."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !isOnboarding {
            Section("Transcription") {
                Picker("Provider", selection: $engine) {
                    ForEach(TranscriptionEnginePreference.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .onChange(of: engine) { _, value in AppPreferences.transcriptionEngine = value }

                Picker("Language", selection: $language) {
                    ForEach(TranscriptionLanguagePreference.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                .onChange(of: language) { _, value in
                    AppPreferences.transcriptionLanguage = value
                    refreshSpeechReadiness()
                }

                Text(copy("Automatic uses a connected, authorized cloud provider when available; otherwise it uses Apple Speech on this Mac. Select On this Mac to keep new transcription local even when you have connected a cloud account. Existing remote jobs keep their original provider.", "Automático usa un proveedor en la nube conectado y autorizado cuando está disponible; en caso contrario, usa Apple Speech en este Mac. Elige En este Mac para mantener las nuevas transcripciones locales aunque tengas una cuenta conectada. Los trabajos remotos existentes conservan su proveedor."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            localSpeechSection
            Section {
                Button(cloudExpanded ? copy("Hide cloud accounts", "Ocultar cuentas en la nube") : copy("Connect optional cloud transcription", "Conectar transcripción opcional en la nube")) {
                    cloudExpanded.toggle()
                }
            }
            }

            if isOnboarding || cloudExpanded {

            Section("Deepgram · optional") {
                setupInstructions(provider: "Deepgram", signup: "https://console.deepgram.com/",
                                  guide: "https://developers.deepgram.com/docs/create-additional-api-keys",
                                  detail: "Sign up, open API Keys in your project, and create a key named Hall-e with transcription access. Copy the secret key when it is shown, then return here.")
                HStack {
                    SecureField("Deepgram API key", text: $deepgramKey)
                    Button("Paste") { pasteKey(into: $deepgramKey) }
                        .help("Paste your copied Deepgram key, then choose Save & test.")
                    Button(deepgramKeyStored ? "Replace & test" : "Save & test") { saveDeepgramKey() }
                        .disabled(deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if deepgramKeyStored {
                        Button("Remove", role: .destructive) {
                            guard removeKey(target: .deepgram) else { return }
                            deepgramKeyStored = false
                            deepgramVerified = false
                        }
                    }
                }.disabled(checkingTarget != nil)
                if deepgramKeyStored {
                    Button("Test saved Deepgram key") { checkKey(target: .deepgram) }
                        .disabled(checkingTarget != nil)
                }
                Text(deepgramVerified ? "Saved key accepted by Deepgram." : "Paste your key and choose Save & test. Existing keys can be tested above.")
                    .font(.caption).foregroundStyle(deepgramVerified ? .green : .secondary)

                Toggle("Allow meeting audio to be uploaded to Deepgram", isOn: Binding(
                    get: { cloudAudioEnabled },
                    set: { enabled in
                        if enabled { cloudConfirmation = .deepgramAudio }
                        else { revokeAudioConsent() }
                    }))
                Text("Audio is sent only for transcription. Speaker 1, Speaker 2, and similar labels distinguish voices; they do not identify people by name. Model improvement is opted out.")
                    .font(.caption).foregroundStyle(.secondary)

                setupStatus(deepgramVerified && cloudAudioEnabled,
                            ready: "Deepgram key checked and audio processing allowed.",
                            pending: !deepgramVerified ? "Test your key to finish connection setup." : "Allow audio processing to finish setup.")

            }

            Section("Speechmatics · optional provider or backup") {
                setupInstructions(provider: "Speechmatics", signup: "https://portal.speechmatics.com/",
                                  guide: "https://docs.speechmatics.com/get-started/authentication",
                                  detail: "Sign up, open API Keys, and create a key for Hall-e. Copy it, then return here. In your portal settings, turn Model Training off before enabling transcription.")
                HStack {
                    SecureField("Speechmatics API key", text: $speechmaticsKey)
                    Button("Paste") { pasteKey(into: $speechmaticsKey) }
                        .help("Choose a region, paste your Speechmatics key, then choose Save & test.")
                    Button(speechmaticsKeyStored ? "Replace & test" : "Save & test") { saveSpeechmaticsKey() }
                        .disabled(speechmaticsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speechmaticsRegion?.isSupported != true)
                    if speechmaticsKeyStored {
                        Button("Remove", role: .destructive) {
                            guard KeychainStore.delete(account: KeychainStore.speechmaticsTranscriptionAccount) else {
                                keyError = "macOS Keychain could not remove the Speechmatics key. Please try again."
                                return
                            }
                            for region in SpeechmaticsRegion.allCases {
                                CloudCredentialValidation.invalidate(target: .speechmatics(region))
                            }
                            speechmaticsKeyStored = false
                            speechmaticsVerified = false
                        }
                    }
                }.disabled(checkingTarget != nil)
                if speechmaticsKeyStored {
                    Button("Test saved Speechmatics key") {
                        if let region = speechmaticsRegion { checkKey(target: .speechmatics(region)) }
                    }.disabled(checkingTarget != nil || speechmaticsRegion?.isSupported != true)
                }
                Text(speechmaticsVerified ? "Saved key accepted in the selected Speechmatics region." : "Choose a region below, then save and test your key.")
                    .font(.caption).foregroundStyle(speechmaticsVerified ? .green : .secondary)

                Text("Choose where Speechmatics processes your audio. Keep the same region for existing jobs.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Processing region", selection: $speechmaticsRegion) {
                    Text("Select a region").tag(SpeechmaticsRegion?.none)
                    ForEach(SpeechmaticsRegion.supportedRegions) { region in
                        Text(region.displayName).tag(Optional(region))
                    }
                }
                .onChange(of: speechmaticsRegion) { _, value in
                    if value != AppPreferences.speechmaticsRegion { revokeSpeechmaticsConsent() }
                    AppPreferences.speechmaticsRegion = value
                    refreshCredentialChecks()
                }
                .disabled(checkingTarget != nil)

                Toggle("I confirmed Model Training is off in Speechmatics", isOn: $speechmaticsTrainingOff)
                    .onChange(of: speechmaticsTrainingOff) { _, value in
                        AppPreferences.speechmaticsModelTrainingConfirmedOff = value
                        if !value { revokeSpeechmaticsConsent() }
                    }

                Toggle("Allow meeting audio to be uploaded to Speechmatics", isOn: Binding(
                    get: { speechmaticsAudioEnabled },
                    set: { enabled in
                        if enabled { cloudConfirmation = .speechmaticsAudio }
                        else { revokeSpeechmaticsConsent() }
                    }))
                    .disabled(speechmaticsRegion?.isSupported != true || !speechmaticsTrainingOff)
                Text("Works on its own, or as the backup in Automatic mode. Multilingual transcription with anonymous speaker labels. Audio and job data may remain in your selected region for up to 7 days.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Setup checklist") {
                if let checkingTarget {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Checking \(checkingTarget.name)…")
                    }
                }
                if isOnboarding {
                    Picker("Provider", selection: $engine) {
                        ForEach(TranscriptionEnginePreference.allCases) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .onChange(of: engine) { _, value in AppPreferences.transcriptionEngine = value }
                }
                setupStatus(deepgramVerified && cloudAudioEnabled,
                            ready: "Deepgram key checked and authorized", pending: "Deepgram needs a checked key and audio permission")
                setupStatus(speechmaticsVerified && speechmaticsAudioEnabled && speechmaticsRegion?.isSupported == true && speechmaticsTrainingOff,
                            ready: "Speechmatics key checked and authorized", pending: "Speechmatics needs a checked key, region, training setting, and audio permission")
                Text("For cloud transcription, one provider is enough. Save & test checks authentication without uploading audio or creating a paid job. It does not verify your balance or guarantee access to every transcription model. On this Mac keeps new transcription local.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Next: finish setup and make a short recording to confirm end-to-end transcription and provider credit. You can change keys anytime in Settings → Transcription.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Spending guard · both providers") {
                HStack {
                    Text("Cloud transcription monthly guard")
                    Spacer()
                    TextField("USD", value: $monthlyLimit, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 80).multilineTextAlignment(.trailing)
                        .onChange(of: monthlyLimit) { _, value in
                            if value.isFinite, value >= 1 { AppPreferences.deepgramMonthlyLimitUSD = value }
                        }
                    Text("USD").font(.caption).foregroundStyle(.secondary)
                }
                Text("Shared by Deepgram and Speechmatics. Completed, in-flight, and ambiguous requests count toward the guard.")
                    .font(.caption).foregroundStyle(.secondary)

                Text("This is an estimated local spending guard, not your provider balance. Trial credits, prices, and limits depend on your account. Failed recordings remain available to retry.")
                    .font(.caption).foregroundStyle(.secondary)

                Link("Deepgram trial & pricing", destination: URL(string: "https://deepgram.com/pricing")!)
                Link("Speechmatics trial & pricing", destination: URL(string: "https://www.speechmatics.com/pricing")!)
                Label("Your keys are stored in macOS Keychain. No developer keys or shared credits are included.", systemImage: "lock.shield")
                    .font(.caption)
            }
            }

            if !isOnboarding {
            Section("Optional integrations") {
                DisclosureGroup("Advanced transcript processing") {
                Toggle("Allow transcript text to be processed by OpenClaw + Gemini", isOn: Binding(
                    get: { cloudReportsEnabled },
                    set: { enabled in
                        if enabled { cloudConfirmation = .reports }
                        else { revokeReportConsent() }
                    }))
                Text("Uses the dedicated tool-less halle-reports agent and a Gemini-only model allowlist. Audio is never included in this step.")
                    .font(.caption).foregroundStyle(.secondary)
            }

                }
            Section {
                Text("Raw transcripts stay local. Summary, decisions, action items, and follow-ups are generated only when AI and cloud transcript processing are enabled in AI Orchestrator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
        .alert("API key setup", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
            Button("OK") { keyError = nil }
        } message: { Text(keyError ?? "") }
        .onAppear {
            refreshSpeechReadiness()
            refreshCredentialChecks()
            cloudExpanded = deepgramKeyStored || speechmaticsKeyStored || engine == .deepgram || engine == .speechmatics
        }
        .onDisappear {
            credentialCheckTask?.cancel()
            credentialCheckTask = nil
            credentialCheckID = nil
            checkingTarget = nil
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshSpeechReadiness() } }
        .confirmationDialog(cloudConfirmation == .reports ? "Allow cloud transcript processing?" : "Allow cloud audio processing?",
                            isPresented: Binding(get: { cloudConfirmation != nil }, set: { if !$0 { cloudConfirmation = nil } }),
                            titleVisibility: .visible) {
            Button("I understand and allow this processing") {
                switch cloudConfirmation {
                case .deepgramAudio: grantAudioConsent()
                case .speechmaticsAudio: grantSpeechmaticsConsent()
                case .reports: grantReportConsent()
                case nil: break
                }
                cloudConfirmation = nil
            }
            Button("Cancel", role: .cancel) { cloudConfirmation = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var localSpeechSection: some View {
        Section(copy("On-device transcription", "Transcripción en este Mac")) {
            Label(speechAuthorized ? copy("Speech permission granted", "Permiso de voz autorizado") : copy("Speech permission needed", "Falta autorizar el reconocimiento de voz"),
                  systemImage: speechAuthorized ? "checkmark.circle" : "exclamationmark.triangle")
            if !speechAuthorized {
                Button(copy("Enable speech recognition", "Activar reconocimiento de voz")) {
                    Task { @MainActor in
                        _ = await LocalTranscriptionProvider.requestAuthorization()
                        refreshSpeechReadiness()
                    }
                }
                Button(copy("Open speech privacy settings", "Abrir privacidad de reconocimiento de voz")) {
                    SystemSettingsOpener.openSpeechPrivacy()
                }
            }
            LabeledContent(copy("Local language model", "Modelo de idioma local")) {
                Text(speechLocale ?? copy("Not available for \(speechLanguage)", "No disponible para \(speechLanguage)"))
                    .foregroundStyle(.secondary)
            }
            if speechLocale == nil {
                Text(copy("macOS may offer the language in Keyboard → Dictation. Return here after enabling or downloading it and check again. Availability depends on your Mac and language; no unrelated language will be substituted.", "macOS puede ofrecer el idioma en Teclado → Dictado. Vuelve después de activarlo o descargarlo y revisa de nuevo. La disponibilidad depende del Mac y del idioma; no se sustituirá por un idioma diferente."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(copy("Open Keyboard settings", "Abrir ajustes de Teclado")) { SystemSettingsOpener.openKeyboardSettings() }
            }
            Button(copy("Check again", "Revisar de nuevo")) { refreshSpeechReadiness() }
            Text(copy("Audio stays on this Mac. Local transcripts do not identify individual speakers. Cloud providers can add anonymous speaker labels when connected and authorized.", "El audio permanece en este Mac. Las transcripciones locales no identifican hablantes individuales. Los proveedores en la nube pueden agregar etiquetas anónimas de hablantes si los conectas y autorizas."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshSpeechReadiness() {
        speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        speechLocale = LocalTranscriptionProvider.firstAvailableRecognizer(language: speechLanguage)?.1
    }

    private func setupInstructions(provider: String, signup: String, guide: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Link("Sign up / open \(provider) ↗", destination: URL(string: signup)!)
                    .buttonStyle(.borderedProminent)
                Link("Key creation guide ↗", destination: URL(string: guide)!)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Text("Already have an account? Use a key from your own account.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setupStatus(_ complete: Bool, ready: String, pending: String) -> some View {
        Label(complete ? ready : pending, systemImage: complete ? "checkmark.circle.fill" : "circle")
            .font(.caption).foregroundStyle(complete ? .green : .secondary)
    }

    private func pasteKey(into field: Binding<String>) {
        // Read the clipboard only in direct response to the user's Paste action.
        guard let value = NSPasteboard.general.string(forType: .string),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            keyError = "Copy your API key from the provider’s website first, then press Paste."
            return
        }
        field.wrappedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveDeepgramKey() {
        checkKey(target: .deepgram, replacement: deepgramKey)
    }

    private func saveSpeechmaticsKey() {
        guard let region = speechmaticsRegion else { return }
        checkKey(target: .speechmatics(region), replacement: speechmaticsKey)
    }

    private func refreshCredentialChecks() {
        deepgramKeyStored = KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount)
        speechmaticsKeyStored = KeychainStore.exists(account: KeychainStore.speechmaticsTranscriptionAccount)
        deepgramVerified = CloudCredentialValidation.savedKeyIsVerified(target: .deepgram)
        speechmaticsVerified = speechmaticsRegion.map {
            CloudCredentialValidation.savedKeyIsVerified(target: .speechmatics($0))
        } ?? false
    }

    private func removeKey(target: CloudCredentialTarget) -> Bool {
        guard KeychainStore.delete(account: target.account) else {
            keyError = "macOS Keychain could not remove the \(target.name) key. Please try again."
            return false
        }
        CloudCredentialValidation.invalidate(target: target)
        return true
    }

    private func checkKey(target: CloudCredentialTarget, replacement: String? = nil) {
        guard checkingTarget == nil else { return }
        checkingTarget = target
        keyError = nil
        let checkID = UUID()
        credentialCheckID = checkID
        credentialCheckTask = Task { @MainActor in
            defer {
                if credentialCheckID == checkID {
                    refreshCredentialChecks()
                    checkingTarget = nil
                    credentialCheckTask = nil
                    credentialCheckID = nil
                }
            }
            do {
                try await CloudCredentialValidation.checkAndSave(target: target, replacement: replacement)
                try Task.checkCancellation()
                if replacement != nil {
                    switch target {
                    case .deepgram: deepgramKey = ""; deepgramKeyStored = true
                    case .speechmatics: speechmaticsKey = ""; speechmaticsKeyStored = true
                    }
                }
            } catch {
                guard !Task.isCancelled, credentialCheckID == checkID else { return }
                keyError = error.localizedDescription
            }
        }
    }

    private func grantAudioConsent() {
        AppPreferences.cloudAudioConsent = .grant(processor: "Deepgram",
                                                  purpose: "prerecorded meeting transcription and diarization")
        cloudAudioEnabled = true
    }

    private func revokeAudioConsent() {
        if var consent = AppPreferences.cloudAudioConsent { consent.revoke(); AppPreferences.cloudAudioConsent = consent }
        cloudAudioEnabled = false
    }

    private func grantSpeechmaticsConsent() {
        guard let region = speechmaticsRegion, speechmaticsTrainingOff else { return }
        AppPreferences.speechmaticsAudioConsent = .grant(
            processor: region.consentProcessor,
            purpose: "prerecorded meeting transcription and speaker diarization; provider retention up to 7 days")
        speechmaticsAudioEnabled = true
    }

    private func revokeSpeechmaticsConsent() {
        if var consent = AppPreferences.speechmaticsAudioConsent {
            consent.revoke(); AppPreferences.speechmaticsAudioConsent = consent
        }
        speechmaticsAudioEnabled = false
    }

    private func grantReportConsent() {
        AppPreferences.cloudTranscriptConsent = .grant(processor: "OpenClaw + GitHub Copilot/Gemini",
                                                       purpose: "structured meeting briefing generation")
        cloudReportsEnabled = true
    }

    private func revokeReportConsent() {
        if var consent = AppPreferences.cloudTranscriptConsent { consent.revoke(); AppPreferences.cloudTranscriptConsent = consent }
        cloudReportsEnabled = false
    }

    private var confirmationMessage: String {
        switch cloudConfirmation {
        case .deepgramAudio:
            "Meeting audio will be sent to Deepgram. Confirm participant notice/consent as required."
        case .speechmaticsAudio:
            "Meeting audio will be sent to Speechmatics in the selected region and may remain there for up to 7 days. Confirm participant notice/consent, region, and that Model Training is off."
        case .reports:
            "Transcript text will be sent through local OpenClaw to GitHub Copilot/Gemini under the currently presented provider terms."
        case nil:
            ""
        }
    }
}
