import SwiftUI
import Speech

struct TranscriptionSettingsView: View {
    @State private var resolvedLocale: String?
    @State private var speechAuthorized = SFSpeechRecognizer.authorizationStatus() == .authorized

    var body: some View {
        Form {
            Section("On-device transcription") {
                HStack {
                    Image(systemName: speechAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(speechAuthorized ? .green : .orange)
                    Text("Speech Recognition permission")
                    Spacer()
                    Text(speechAuthorized ? "Granted" : "Not granted").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Recognizer locale") {
                    Text(resolvedLocale ?? "checking…")
                }
                Text("Hall-e transcribes recordings on-device (nothing is uploaded). It uses the first available model in: es-CL → es-419 → es-MX → es-ES → en-US. If none is on-device, add a Spanish dictation language in System Settings → Keyboard → Dictation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Cleaned transcript, summary, decisions, and action items are produced only if you enable AI and cloud transcript processing in AI Orchestrator. The raw transcript itself is always local.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
        .onAppear {
            resolvedLocale = LocalTranscriptionProvider.firstAvailableRecognizer()?.1 ?? "none available"
        }
    }
}
