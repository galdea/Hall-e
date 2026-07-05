import Foundation
import AppKit

/// End-to-end recording flow: ensure note → consent → record → transcribe →
/// merge transcript into the note → (AI-gated) enrich. Each step is idempotent
/// and failures are isolated (a transcription failure still leaves a usable note
/// and audio file).
@MainActor
enum RecordingCoordinator {
    static func startRecording(for event: UnifiedEvent) {
        guard VaultAccess.isReachable(), let service = MeetingNoteService.make() else {
            presentAlert("Choose an Obsidian vault first", "Settings → Obsidian.")
            return
        }
        guard RecordingService.shared.isRecording == false else { return }

        // Consent reminder before any capture.
        let consent = NSAlert()
        consent.messageText = "Record this meeting?"
        consent.informativeText = "Hall-e will record your microphone locally and attach the audio to the meeting note. Let participants know they're being recorded."
        consent.addButton(withTitle: "Start Recording")
        consent.addButton(withTitle: "Cancel")
        guard consent.runModal() == .alertFirstButtonReturn else { return }

        // Ensure the note exists so the recording has somewhere to attach.
        let notePath: String?
        do {
            let descriptor = try service.createOrFindMeetingNote(for: event, projectName: event.projectId)
            notePath = descriptor.vaultRelativePath
        } catch {
            notePath = nil
            Log.rec.error("note ensure failed: \(error, privacy: .public)")
        }

        Task {
            await RecordingService.shared.start(for: event, notePath: notePath) { session in
                Task { await transcribeAndMerge(session: session, event: event) }
            }
        }
    }

    /// Runs after recording stops.
    static func transcribeAndMerge(session: RecordingSession, event: UnifiedEvent) async {
        guard let service = MeetingNoteService.make(), let notePath = session.notePath else { return }
        let pb = VaultPathBuilder(config: service.config)
        let writer = VaultWriter(vaultURL: service.vaultURL)

        try? writer.updateFrontmatter(relativePath: notePath, key: "recording_path",
                                      value: session.folderURL.path, pathBuilder: pb)
        try? writer.updateFrontmatter(relativePath: notePath, key: "transcript_status",
                                      value: "inProgress", pathBuilder: pb)

        // Transcribe off the main actor.
        let transcript: Transcript?
        do {
            transcript = try await LocalTranscriptionProvider()
                .transcribe(fileURL: session.micURL, sessionID: session.id, track: "mic")
        } catch {
            Log.rec.error("transcription failed: \(error, privacy: .public)")
            try? writer.updateFrontmatter(relativePath: notePath, key: "transcript_status",
                                          value: "failed", pathBuilder: pb)
            return
        }
        guard let transcript else { return }
        TranscriptStore.save(transcript, to: session)

        // Merge transcript text into the note (replaces the placeholder).
        try? writer.mergeSection(relativePath: notePath, section: "transcript",
                                 newContent: transcript.plainText.isEmpty ? "_(no speech recognized)_" : transcript.plainText,
                                 headingAnchor: "Transcript", mode: .replace, pathBuilder: pb)
        try? writer.updateFrontmatter(relativePath: notePath, key: "transcript_status",
                                      value: "completed", pathBuilder: pb)

        // AI enrichment (gated on cloud-processing toggle).
        let context = MeetingContext(title: event.title, project: event.projectId,
                                     date: HalleDate.day(event.startTs),
                                     attendees: event.attendees.compactMap { $0.email })
        await TranscriptPostProcessor(service: service, notePath: notePath, context: context)
            .enrich(transcript: transcript.plainText)

        Log.rec.info("recording pipeline complete for \(event.title, privacy: .public)")
    }

    private static func presentAlert(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info; a.runModal()
    }
}
