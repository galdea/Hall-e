import SwiftUI
import Speech

struct TranscriptionSettingsView: View {
    @State private var engine = AppPreferences.transcriptionEngine
    @State private var language = AppPreferences.transcriptionLanguage
    @State private var speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
    @State private var modelManager = WhisperKitModelManager.shared
    @State private var deepgramKey = ""
    @State private var deepgramKeyStored = KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount)
    @State private var cloudAudioEnabled = AppPreferences.allowCloudAudioTranscription
    @State private var cloudReportsEnabled = AppPreferences.allowCloudTranscriptReports
    @State private var monthlyLimit = AppPreferences.deepgramMonthlyLimitUSD
    @State private var cloudConfirmation: CloudConfirmation?
    @State private var creditAlertStatus: String?

    private enum CloudConfirmation: String, Identifiable { case audio, reports; var id: String { rawValue } }

    private var speechLanguage: String { language.sfSpeechCode }
    private var speechLocale: String? {
        LocalTranscriptionProvider.firstAvailableRecognizer(language: speechLanguage)?.1
    }

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Engine", selection: $engine) {
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

                Text("Automatic language detection is available in WhisperKit. For code-switched meetings, pin the dominant language when the detected language flips between windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Deepgram cloud transcription") {
                HStack {
                    SecureField("Rotated Deepgram API key", text: $deepgramKey)
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
                        if enabled { cloudConfirmation = .audio }
                        else { revokeAudioConsent() }
                    }))
                Text("Separate from transcript-text processing. Hall-e requests Nova-3 multilingual, diarization v2, and Model Improvement Program opt-out. You remain responsible for participant notice and lawful recording/cloud processing.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Text("Monthly spend guard")
                    Spacer()
                    TextField("USD", value: $monthlyLimit, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit { AppPreferences.deepgramMonthlyLimitUSD = monthlyLimit }
                    Text("USD").font(.caption).foregroundStyle(.secondary)
                }
                Text("Default: USD 25. Completed, in-flight, and ambiguous requests count toward the guard.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Send test credit alert") { Task { await sendCreditAlertTest() } }
                    if let creditAlertStatus {
                        Text(creditAlertStatus).font(.caption)
                            .foregroundStyle(creditAlertStatus.hasPrefix("Delivered") ? .green : .orange)
                    }
                }
                Text("Hall-e notifies you when the Deepgram account runs out of credit, or when the monthly guard pauses uploads. Balance cannot be polled with a transcription-only key, so the alert is raised from the failed request itself. Recordings are always kept and stay retryable.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Automatic corporate reports") {
                Toggle("Allow transcript text to be processed by OpenClaw + Gemini", isOn: Binding(
                    get: { cloudReportsEnabled },
                    set: { enabled in
                        if enabled { cloudConfirmation = .reports }
                        else { revokeReportConsent() }
                    }))
                Text("Uses the dedicated tool-less halle-reports agent and a Gemini-only model allowlist. Audio is never included in this step.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("WhisperKit model") {
                HStack {
                    Image(systemName: modelManager.isModelDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(modelManager.isModelDownloaded ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Large v3 · 626 MB")
                        Text(AppPreferences.whisperKitModel).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    modelAction
                }

                if case .downloading(let progress) = modelManager.state {
                    ProgressView(value: progress)
                    Text("Downloading model… \(Int(progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                } else if case .preparing = modelManager.state {
                    ProgressView()
                    Text("Preparing model for this Mac (one-time)…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if case .failed(let message) = modelManager.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                Text("The model is stored locally in Application Support. Automatic transcription prepares it on launch when needed; you can also start the download here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Apple Speech (explicit only)") {
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
                Text("Automatic and WhisperKit never fall back silently. Apple Speech is used only when you select it explicitly, and its locale list is restricted to the selected language.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Raw transcripts stay local. Summary, decisions, action items, and follow-ups are generated only when AI and cloud transcript processing are enabled in AI Orchestrator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
        .onAppear {
            speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized
            modelManager.refresh()
        }
        .confirmationDialog(cloudConfirmation == .audio ? "Allow cloud audio processing?" : "Allow cloud transcript processing?",
                            isPresented: Binding(get: { cloudConfirmation != nil }, set: { if !$0 { cloudConfirmation = nil } }),
                            titleVisibility: .visible) {
            Button("I understand and allow this processing") {
                if cloudConfirmation == .audio { grantAudioConsent() } else { grantReportConsent() }
                cloudConfirmation = nil
            }
            Button("Cancel", role: .cancel) { cloudConfirmation = nil }
        } message: {
            Text(cloudConfirmation == .audio
                 ? "Third-party meeting audio will leave this Mac. Confirm participant notice/consent as required."
                 : "Transcript text will be sent through local OpenClaw to GitHub Copilot/Gemini under the currently presented provider terms.")
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch modelManager.state {
        case .ready:
            Button("Remove") { modelManager.removeModel() }.buttonStyle(.bordered)
        case .downloading, .preparing:
            ProgressView().controlSize(.small)
        case .notDownloaded, .failed:
            Button("Download & prepare") {
                Task { await modelManager.downloadAndPrepare() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Verifies the credit alert end-to-end from the running app, which is the
    /// only context where notification authorization is real.
    private func sendCreditAlertTest() async {
        let outcome = await DeepgramCreditMonitor.notify(.creditExhausted,
            detail: "Test alert. This is what you will see when the Deepgram account runs out of credit.")
        switch outcome {
        case .posted: creditAlertStatus = "Delivered — check Notification Centre"
        case .throttled: creditAlertStatus = "Already alerted in the last 24 h"
        case .notAuthorized: creditAlertStatus = "Blocked — allow Hall-e notifications in System Settings"
        case .failed(let detail): creditAlertStatus = "Failed — \(detail)"
        }
        DeepgramCreditMonitor.resetThrottle()
    }

    private func saveDeepgramKey() {
        let value = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try KeychainStore.set(value, account: KeychainStore.deepgramTranscriptionAccount)
            deepgramKey = ""; deepgramKeyStored = true
        } catch { deepgramKeyStored = false }
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

    private func grantReportConsent() {
        AppPreferences.cloudTranscriptConsent = .grant(processor: "OpenClaw + GitHub Copilot/Gemini",
                                                       purpose: "structured meeting briefing generation")
        cloudReportsEnabled = true
    }

    private func revokeReportConsent() {
        if var consent = AppPreferences.cloudTranscriptConsent { consent.revoke(); AppPreferences.cloudTranscriptConsent = consent }
        cloudReportsEnabled = false
    }
}
