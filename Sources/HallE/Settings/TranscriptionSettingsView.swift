import SwiftUI
import Speech
import AppKit

struct TranscriptionSettingsView: View {
    var isOnboarding = false
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

    private enum CloudConfirmation: String, Identifiable {
        case deepgramAudio, speechmaticsAudio, reports
        var id: String { rawValue }
    }

    private var speechLanguage: String { language.sfSpeechCode }
    private var speechLocale: String? {
        LocalTranscriptionProvider.firstAvailableRecognizer(language: speechLanguage)?.1
    }

    var body: some View {
        Form {
            Section("Your accounts, your keys") {
                Text("Hall-e is free and needs no Hall-e login. Create your own Deepgram or Speechmatics account below. No developer keys or shared credits are included.")
                Text("Eligible trial credit is enough to get started with recording and transcription—no paid Hall-e subscription needed. Provider allowances, expiry, and model access vary; check your account before adding paid credit.")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Keys are saved only in your macOS Keychain, never shared with Hall-e’s developers.", systemImage: "lock.shield")
                    .font(.caption)
            }

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
                .onChange(of: language) { _, value in AppPreferences.transcriptionLanguage = value }

                Text("Choose Automatic and connect either provider below. We recommend both: Hall-e can switch from Deepgram to Speechmatics when Deepgram reports exhausted credit. Each provider needs your permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("1. Connect Deepgram") {
                setupInstructions(provider: "Deepgram", signup: "https://console.deepgram.com/",
                                  guide: "https://developers.deepgram.com/docs/create-additional-api-keys",
                                  detail: "Sign up, open API Keys in your project, and create a key named Hall-e with transcription access. Copy the secret key when it is shown, then return here.")
                HStack {
                    SecureField("Deepgram API key", text: $deepgramKey)
                    Button("Paste") { pasteKey(into: $deepgramKey) }
                        .help("Paste your copied Deepgram key; nothing is saved until you press Save.")
                    Button(deepgramKeyStored ? "Replace" : "Save") { saveDeepgramKey() }
                        .disabled(deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if deepgramKeyStored {
                        Button("Remove", role: .destructive) {
                            KeychainStore.delete(account: KeychainStore.deepgramTranscriptionAccount)
                            deepgramKeyStored = false
                        }
                    }
                }
                Text(deepgramKeyStored ? "Key saved. Next: allow transcription below." : "Paste your own key above, then press Save.")
                    .font(.caption).foregroundStyle(deepgramKeyStored ? .green : .secondary)

                Toggle("Allow meeting audio to be uploaded to Deepgram", isOn: Binding(
                    get: { cloudAudioEnabled },
                    set: { enabled in
                        if enabled { cloudConfirmation = .deepgramAudio }
                        else { revokeAudioConsent() }
                    }))
                Text("Audio is sent only for transcription. Speaker 1, Speaker 2, and similar labels distinguish voices; they do not identify people by name. Model improvement is opted out.")
                    .font(.caption).foregroundStyle(.secondary)

                setupStatus(deepgramKeyStored && cloudAudioEnabled,
                            ready: "Deepgram setup complete · key validity is checked on your first transcription.",
                            pending: deepgramKeyStored ? "Allow audio processing to finish setup." : "Save your key to continue.")

            }

            Section("2. Connect Speechmatics · recommended backup") {
                setupInstructions(provider: "Speechmatics", signup: "https://portal.speechmatics.com/",
                                  guide: "https://docs.speechmatics.com/get-started/authentication",
                                  detail: "Sign up, open API Keys, and create a key for Hall-e. Copy it, then return here. In your portal settings, turn Model Training off before enabling transcription.")
                HStack {
                    SecureField("Speechmatics API key", text: $speechmaticsKey)
                    Button("Paste") { pasteKey(into: $speechmaticsKey) }
                        .help("Paste your copied Speechmatics key; nothing is saved until you press Save.")
                    Button(speechmaticsKeyStored ? "Replace" : "Save") { saveSpeechmaticsKey() }
                        .disabled(speechmaticsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if speechmaticsKeyStored {
                        Button("Remove", role: .destructive) {
                            KeychainStore.delete(account: KeychainStore.speechmaticsTranscriptionAccount)
                            speechmaticsKeyStored = false
                        }
                    }
                }
                Text(speechmaticsKeyStored ? "Key saved. Next: choose a region and allow transcription below." : "Paste your own key above, then press Save.")
                    .font(.caption).foregroundStyle(speechmaticsKeyStored ? .green : .secondary)

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
                }

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
                setupStatus(deepgramKeyStored && cloudAudioEnabled,
                            ready: "Deepgram configured", pending: "Deepgram not configured")
                setupStatus(speechmaticsKeyStored && speechmaticsAudioEnabled && speechmaticsRegion?.isSupported == true && speechmaticsTrainingOff,
                            ready: "Speechmatics configured", pending: "Speechmatics needs a key, region, training setting, and audio permission")
                Text("One configured provider is enough. Keep Provider set to Automatic to use either, and to enable credit-exhaustion fallback when both are configured. Saving a key does not upload audio or verify your balance.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Next: finish setup and make a short recording. Its transcript confirms that your key and provider credit work. You can change keys anytime in Settings → Transcription.")
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
            Section("Apple Speech (optional)") {
                DisclosureGroup("On-device transcription") {
                HStack {
                    Image(systemName: speechAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(speechAuthorized ? .green : .orange)
                    Text("Speech Recognition permission")
                    Spacer()
                    Text(speechAuthorized ? "Granted" : "Not granted")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Selected language model")
                    Spacer()
                    Text(speechLocale ?? "none available")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if speechLocale == nil {
                    Label("None for \(speechLanguage == "es" ? "Spanish" : language.displayName.lowercased()) — transcription will fail rather than use English.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Apple Speech is used only when selected. The language setting applies to Apple Speech; cloud providers detect languages automatically.")
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
            speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
        }
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
        let value = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try KeychainStore.set(value, account: KeychainStore.deepgramTranscriptionAccount)
            deepgramKey = ""; deepgramKeyStored = true
        } catch { keyError = "macOS Keychain could not save the key. Your existing key was preserved. Please try again." }
    }

    private func saveSpeechmaticsKey() {
        let value = speechmaticsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try KeychainStore.set(value, account: KeychainStore.speechmaticsTranscriptionAccount)
            speechmaticsKey = ""; speechmaticsKeyStored = true
        } catch { keyError = "macOS Keychain could not save the key. Your existing key was preserved. Please try again." }
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
