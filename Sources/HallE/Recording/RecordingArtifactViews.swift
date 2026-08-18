import SwiftUI
import AppKit
import AVFoundation

enum MeetingArtifactMode: String, CaseIterable, Identifiable {
    case recording, transcript
    var id: String { rawValue }
}

struct RecordingPromptBanner: View {
    @State private var recorder = RecordingService.shared
    var body: some View {
        if let notice = recorder.noticeText, recorder.isRecording {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                Text(notice).font(.caption).lineLimit(2)
                Spacer()
                if recorder.scheduledEndPromptVisible {
                    Button("Extend 5 min") { recorder.extendScheduledEnd() }.controlSize(.small)
                } else if recorder.silencePromptVisible {
                    Button("Keep") { recorder.keepRecordingAfterSilence() }.controlSize(.small)
                }
                Button("Stop") {
                    recorder.stop(reason: recorder.scheduledEndPromptVisible ? .scheduledEnd : .silencePrompt)
                }.controlSize(.small).buttonStyle(.borderedProminent).tint(.red)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
        }
    }
}

struct RecordingTransportView: View {
    let session: RecordingSession
    @State private var playback = RecordingPlaybackService.shared
    @State private var seekingValue: TimeInterval = 0
    @State private var isSeeking = false

    private var active: Bool { playback.activeSessionID == session.id }
    private var current: TimeInterval { active ? playback.currentTime : 0 }
    private var duration: TimeInterval { active ? playback.duration : Self.fileDuration(session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Button { playback.toggle(session) } label: {
                    Image(systemName: active && playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                Slider(value: Binding(get: { isSeeking ? seekingValue : current }, set: { seekingValue = $0 }),
                       in: 0...max(1, duration), onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing { playback.seek(to: seekingValue) }
                })
                Text("\((isSeeking ? seekingValue : current).artifactDuration) / \(duration.artifactDuration)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 82)
            }
            if active, let error = playback.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text(session.stopReason.map { "Stopped: \($0.displayName)" } ?? "Local recording")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([session.playbackURL]) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    private static func fileDuration(_ session: RecordingSession) -> TimeInterval {
        (try? AVAudioPlayerDuration.duration(url: session.playbackURL)) ?? 0
    }
}

struct TranscriptReaderView: View {
    let session: RecordingSession
    @State private var query = ""
    @State private var showRetranscriptionConfirmation = false

    private var transcript: String { RecordingStore.transcriptText(for: session) ?? "" }
    private var visibleText: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }
        let matches = transcript.components(separatedBy: .newlines).filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        return matches.isEmpty ? "No transcript lines match “\(query)”." : matches.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search transcript", text: $query).textFieldStyle(.plain)
                Button { copyTranscript() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy transcript")
                if session.transcriptStatus == .completed {
                    Button { showRetranscriptionConfirmation = true } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-transcribe recording")
                }
                if let note = session.notePath {
                    Button { openNote(note) } label: { Image(systemName: "note.text") }
                        .buttonStyle(.borderless).help("Open meeting note")
                }
            }
            Divider()
            if session.transcriptStatus == .completed, !transcript.isEmpty {
                ScrollView {
                    Text(visibleText).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 90, maxHeight: 190)
            } else {
                Label(transcriptStatusText, systemImage: transcriptStatusSymbol)
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                if session.transcriptStatus == .failed { TranscriptionRecoveryControls(session: session) }
            }
        }
        .confirmationDialog("Re-transcribe this recording?", isPresented: $showRetranscriptionConfirmation,
                            titleVisibility: .visible) {
            Button("Re-transcribe", role: .destructive) {
                RecordingCoordinator.retranscribe(session: session)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The existing transcript will be replaced using the current engine and language settings.")
        }
    }

    private var transcriptStatusText: String {
        switch session.transcriptStatus {
        case .pending: "Transcript is waiting to be processed."
        case .inProgress: "Transcript is being generated…"
        case .completed: "The completed transcript is empty."
        case .failed: "Transcription failed; the recording remains available."
        }
    }
    private var transcriptStatusSymbol: String {
        session.transcriptStatus == .failed ? "exclamationmark.triangle" : "waveform"
    }
    private func copyTranscript() {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(transcript, forType: .string)
    }
    private func openNote(_ relative: String) {
        guard let root = VaultAccess.currentVaultURL() else { return }
        let folder = ObsidianVaultConfig.load()?.subfolderName ?? "Hall-e"
        NSWorkspace.shared.open(root.appendingPathComponent(folder).appendingPathComponent(relative))
    }
}

/// Actionable recovery for a durable transcription failure. The retry always
/// starts from the persisted audio/checkpoints, never from an in-memory task.
struct TranscriptionRecoveryControls: View {
    let session: RecordingSession

    private var job: TranscriptionJob { session.transcriptionJob ?? .legacy(status: session.transcriptStatus) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = job.lastError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(TranscriptionErrorSanitizer.guidance(for: job.lastError))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Retry") { RecordingCoordinator.retry(session: session) }
                    .buttonStyle(.borderedProminent)
                Button("Retry all failed") { RecordingCoordinator.retryAll() }
                    .buttonStyle(.bordered)
                Button("Reveal audio") { NSWorkspace.shared.activateFileViewerSelecting([session.folderURL]) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct MeetingArtifactPanel: View {
    let session: RecordingSession
    @Binding var mode: MeetingArtifactMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("", selection: Binding(get: { mode ?? .recording }, set: { mode = $0 })) {
                    Label("Recording", systemImage: "waveform").tag(MeetingArtifactMode.recording)
                    Label("Transcript", systemImage: "text.quote").tag(MeetingArtifactMode.transcript)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 250)
                Spacer()
                Button { mode = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close")
            }
            if mode == .transcript { TranscriptReaderView(session: session) }
            else { RecordingTransportView(session: session) }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

private enum AVAudioPlayerDuration {
    static func duration(url: URL) throws -> TimeInterval {
        try AVAudioPlayer(contentsOf: url).duration
    }
}

private extension TimeInterval {
    var artifactDuration: String {
        guard isFinite else { return "00:00" }
        let seconds = max(0, Int(self))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private extension RecordingStopReason {
    var displayName: String {
        switch self {
        case .manual: "manually"
        case .scheduledEnd: "scheduled end"
        case .sourceEnded: "audio source ended"
        case .silencePrompt: "silence confirmation"
        case .recorderFinished: "audio finished"
        case .recorderFailed: "recorder error"
        }
    }
}
