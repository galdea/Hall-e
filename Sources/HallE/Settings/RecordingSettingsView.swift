import SwiftUI
import AVFoundation
import Speech

struct RecordingSettingsView: View {
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var speechStatus = SFSpeechRecognizer.authorizationStatus()
    @State private var autoRecordCalendar = AppPreferences.autoRecordCalendarMeetings
    @State private var stopAtScheduledEnd = AppPreferences.stopRecordingAtScheduledEnd
    @State private var detectSilence = AppPreferences.silenceDetectionEnabled
    @State private var autoStopSilence = AppPreferences.silenceAutoStopEnabled
    @State private var silenceSeconds = AppPreferences.recordingSilenceSeconds
    @State private var confirmationSeconds = AppPreferences.recordingConfirmationSeconds
    @State private var retitling = false
    @State private var retitleResult: String?

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow("Microphone", ok: micStatus == .authorized,
                              detail: statusText(micStatus.rawValue == AVAuthorizationStatus.authorized.rawValue))
                Button("Request microphone access") {
                    Task { _ = await RecordingService.shared.requestMicAccess()
                        micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                }
                .disabled(micStatus == .authorized)
            }

            Section("How recording works") {
                Toggle("Automatically record when I join a meeting from Hall-e", isOn: $autoRecordCalendar)
                    .onChange(of: autoRecordCalendar) { _, value in
                        AppPreferences.autoRecordCalendarMeetings = value
                    }
                Toggle("Stop exactly at the scheduled meeting end", isOn: $stopAtScheduledEnd)
                    .onChange(of: stopAtScheduledEnd) { _, value in
                        AppPreferences.stopRecordingAtScheduledEnd = value
                    }
                Label("A red menu-bar icon shows while recording", systemImage: "record.circle")
                Label("Audio is saved locally, outside your vault", systemImage: "internaldrive")
                Label("Manual recordings show a consent reminder", systemImage: "exclamationmark.bubble")
                Label("Completed meetings show playback and transcript controls in the calendar", systemImage: "play.circle")
                Label("Keep recording after the meeting ends unless exact-end stopping is enabled", systemImage: "calendar.badge.clock")
                Text("Recordings live in ~/Library/Application Support/Hall-e/Recordings and are linked to the meeting note via its recording_path.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Only Hall-e’s Join button triggers automatic recording. Calendar events without a meeting link, and meetings opened outside Hall-e, are not recorded automatically. Enable this only when recording is permitted and participants are informed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Silence and automatic stop") {
                Toggle("Ask to stop when no voice is detected", isOn: $detectSilence)
                    .onChange(of: detectSilence) { _, value in AppPreferences.silenceDetectionEnabled = value }
                Stepper("Ask after \(Int(silenceSeconds)) seconds without voice", value: $silenceSeconds, in: 5...300, step: 5)
                    .onChange(of: silenceSeconds) { _, value in AppPreferences.recordingSilenceSeconds = value }
                    .disabled(!detectSilence)
                Toggle("Stop automatically if I do not respond", isOn: $autoStopSilence)
                    .onChange(of: autoStopSilence) { _, value in AppPreferences.silenceAutoStopEnabled = value }
                    .disabled(!detectSilence)
                Stepper("Allow \(Int(confirmationSeconds)) seconds to respond", value: $confirmationSeconds, in: 5...120, step: 5)
                    .onChange(of: confirmationSeconds) { _, value in AppPreferences.recordingConfirmationSeconds = value }
                    .disabled(!detectSilence || !autoStopSilence)
                Text("Speech resuming cancels the countdown. Keep recording dismisses the prompt until speech resumes and another quiet period occurs. Voice detection runs on this Mac; unavailable audio analysis never counts as silence.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset silence defaults") {
                    detectSilence = true; autoStopSilence = true; silenceSeconds = 20; confirmationSeconds = 20
                }
            }

            Section("Library") {
                Label("Recordings are kept indefinitely — Hall-e never expires or prunes them",
                      systemImage: "infinity")
                Label("Each recording is filed under its project, e.g. Recordings/Accurate",
                      systemImage: "folder")
                Label("New recordings are named after their transcript and participants",
                      systemImage: "text.badge.checkmark")
                HStack {
                    Button(retitling ? "Renaming…" : "Rename existing recordings from their transcripts") {
                        retitle()
                    }
                    .disabled(retitling)
                    if let retitleResult {
                        Text(retitleResult).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Recordings made before this feature keep their calendar title. Renaming sends each stored transcript to your configured AI provider, so it only runs when you ask for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Calls") {
                Text("Manage Chrome, Zoom, WhatsApp, and approved custom call domains in Browser & Calls. Each detection asks before recording; Hall-e never starts a call recording automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Call recordings capture your microphone plus best-effort app audio. If macOS denies System Audio Recording or an app cannot be tapped, Hall-e keeps the microphone recording and marks that limitation on the session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recording")
    }

    private func retitle() {
        retitling = true
        retitleResult = nil
        Task { @MainActor in
            let count = await RecordingLibrary.retitleTranscribedRecordings()
            retitling = false
            retitleResult = count == 0 ? "Nothing to rename" : "Renamed \(count)"
        }
    }

    private func permissionRow(_ name: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(name)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func statusText(_ ok: Bool) -> String { ok ? "Granted" : "Not granted" }
}
