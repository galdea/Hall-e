import SwiftUI
import Speech

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

            Section("Deepgram cloud transcription") {
                HStack {
                    SecureField("Deepgram API key", text: $deepgramKey)
                    Button(deepgramKeyStored ? "Replace" : "Save") { saveDeepgramKey() }
                        .disabled(deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if deepgramKeyStored {
                        Button("Remove", role: .destructive) {
                            KeychainStore.delete(account: KeychainStore.deepgramTranscriptionAccount)
                            deepgramKeyStored = false
                        }
                    }
                }
                Text(deepgramKeyStored ? "Key stored in macOS Keychain" : "No Deepgram key stored")
                    .font(.caption).foregroundStyle(deepgramKeyStored ? .green : .secondary)

                Toggle("Allow meeting audio to be uploaded to Deepgram", isOn: Binding(
                    get: { cloudAudioEnabled },
                    set: { enabled in
                        if enabled { cloudConfirmation = .deepgramAudio }
                        else { revokeAudioConsent() }
                    }))
                Text("Audio is sent only for transcription. Speaker 1, Speaker 2, and similar labels distinguish voices; they do not identify people by name. Model improvement is opted out.")
                    .font(.caption).foregroundStyle(.secondary)

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

                Link("Get a Deepgram API key ↗", destination: URL(string: "https://console.deepgram.com/")!)
                Text("This is an estimated local spending guard, not your provider balance. Trial credits, prices, and limits depend on your account. Failed recordings remain available to retry.")
                    .font(.caption).foregroundStyle(.secondary)

            }

            Section("Speechmatics") {
                HStack {
                    SecureField("Speechmatics API key", text: $speechmaticsKey)
                    Button(speechmaticsKeyStored ? "Replace" : "Save") { saveSpeechmaticsKey() }
                        .disabled(speechmaticsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if speechmaticsKeyStored {
                        Button("Remove", role: .destructive) {
                            KeychainStore.delete(account: KeychainStore.speechmaticsTranscriptionAccount)
                            speechmaticsKeyStored = false
                        }
                    }
                }
                Link("Get a Speechmatics API key ↗", destination: URL(string: "https://portal.speechmatics.com/")!)
                Text(speechmaticsKeyStored ? "Key stored in macOS Keychain" : "No Speechmatics key stored")
                    .font(.caption).foregroundStyle(speechmaticsKeyStored ? .green : .secondary)

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
        .alert("Could not save API key", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
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
