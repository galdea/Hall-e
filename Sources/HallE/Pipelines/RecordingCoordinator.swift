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
    static func transcribeAndMerge(session incoming: RecordingSession, event: UnifiedEvent) async {
        var session = incoming
        guard let service = MeetingNoteService.make(), let notePath = session.notePath else { return }
        let pb = VaultPathBuilder(config: service.config)
        let writer = VaultWriter(vaultURL: service.vaultURL)

        try? writer.updateFrontmatter(relativePath: notePath, key: "recording_path",
                                      value: session.folderURL.path, pathBuilder: pb)
        session.transcriptStatus = .inProgress; session.save(); notifyRecordingChanged()
        try? writer.updateFrontmatter(relativePath: notePath, key: "transcript_status",
                                      value: "inProgress", pathBuilder: pb)

        // Transcribe off the main actor.
        let transcript: Transcript?
        do {
            transcript = try await LocalTranscriptionProvider()
                .transcribe(fileURL: session.micURL, sessionID: session.id, track: "mic")
        } catch {
            Log.rec.error("transcription failed: \(error, privacy: .public)")
            session.transcriptStatus = .failed; session.save(); notifyRecordingChanged()
            try? writer.updateFrontmatter(relativePath: notePath, key: "transcript_status",
                                          value: "failed", pathBuilder: pb)
            return
        }
        guard let transcript else {
            session.transcriptStatus = .failed; session.save(); notifyRecordingChanged()
            return
        }
        TranscriptStore.save(transcript, to: session)
        session.transcriptStatus = .completed
        session.localeUsed = transcript.localeUsed
        session.save(); notifyRecordingChanged()

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

    // MARK: - WhatsApp call recording

    /// Manual "Record WhatsApp call" entry (also used by the auto-prompt). Records
    /// (mic now; + system audio in Phase C), then transcribes → classifies the
    /// transcript → files a Calls note into the resolved project.
    static func startCallRecording() {
        guard RecordingService.shared.isRecording == false else { return }
        let consent = NSAlert()
        consent.messageText = "¿Grabar esta llamada de WhatsApp?"
        consent.informativeText = "Hall-e grabará el audio localmente y lo transcribirá. Avísale a la otra persona que la llamada está siendo grabada."
        consent.addButton(withTitle: "Grabar")
        consent.addButton(withTitle: "Cancelar")
        guard consent.runModal() == .alertFirstButtonReturn else { return }

        let event = CallEvent.makeWhatsAppCall()
        Task {
            await RecordingService.shared.startCall(for: event, notePath: nil) { session in
                Task { await finishCall(session: session, event: event) }
            }
        }
    }

    /// After a call recording stops: transcribe → classify by transcript → create
    /// the Calls note in the resolved project → merge transcript → enrich.
    static func finishCall(session incoming: RecordingSession, event: UnifiedEvent) async {
        var session = incoming
        session.transcriptStatus = .inProgress; session.save(); notifyRecordingChanged()

        // Transcribe both tracks that exist (mic always; system if captured).
        var segments: [TranscriptSegment] = []
        var localeUsed = "en-US"
        func transcribe(_ url: URL, track: String) async {
            guard FileManager.default.fileExists(atPath: url.path),
                  let t = try? await LocalTranscriptionProvider().transcribe(fileURL: url, sessionID: session.id, track: track)
            else { return }
            segments.append(contentsOf: t.segments)
            localeUsed = t.localeUsed
        }
        await transcribe(session.micURL, track: "mic")
        if session.systemAudioFileName != nil { await transcribe(session.systemAudioURL, track: "them") }

        guard !segments.isEmpty else {
            session.transcriptStatus = .failed; session.save(); notifyRecordingChanged(); return
        }
        segments.sort { $0.start < $1.start }
        let transcript = Transcript(sessionID: session.id, localeUsed: localeUsed,
                                    segments: segments, status: .completed, source: "sfspeech-on-device")
        TranscriptStore.save(transcript, to: session)
        session.transcriptStatus = .completed; session.localeUsed = localeUsed
        session.save(); notifyRecordingChanged()

        // Classify by transcript content (deterministic; AI fallback if enabled).
        var classified = event
        classified.descriptionText = transcript.plainText
        let classifier = MeetingClassifier()
        var result = classifier.classifyTranscript(text: transcript.plainText)
        let provider = LLMProviderFactory.make()
        if !(provider is DisabledLLMProvider), !classifier.isConfident(result),
           let ai = await classifier.aiClassify(classified, provider: provider) {
            result = ai
        }
        let projectName = result.requires_user_confirmation ? nil : result.project
        classified.projectId = projectName
        classified.projectConfidence = result.confidence

        // Create the Calls note in the resolved project (or Calls/Inbox).
        guard let svc = MeetingNoteService.make() else {
            Log.rec.error("no vault; call transcript saved to \(session.folderURL.path, privacy: .public)")
            return
        }
        do {
            let descriptor = try svc.createOrFindMeetingNote(for: classified, projectName: projectName, kind: .call)
            session.notePath = descriptor.vaultRelativePath; session.save()
            let pb = VaultPathBuilder(config: svc.config)
            let writer = VaultWriter(vaultURL: svc.vaultURL)
            try? writer.updateFrontmatter(relativePath: descriptor.vaultRelativePath, key: "recording_path",
                                          value: session.folderURL.path, pathBuilder: pb)
            try? writer.mergeSection(relativePath: descriptor.vaultRelativePath, section: "transcript",
                                     newContent: callTranscriptBody(transcript),
                                     headingAnchor: "Transcript", mode: .replace, pathBuilder: pb)
            let ctx = MeetingContext(title: classified.title, project: projectName,
                                     date: HalleDate.day(classified.startTs), attendees: [])
            await TranscriptPostProcessor(service: svc, notePath: descriptor.vaultRelativePath, context: ctx)
                .enrich(transcript: transcript.plainText)
            Log.rec.info("WhatsApp call filed → \(projectName ?? "Inbox", privacy: .public)")
        } catch {
            Log.rec.error("call note creation failed: \(error, privacy: .public)")
        }
    }

    /// Label each track's text ("Yo:" mic / "Ellos:" system) in speaking order.
    private static func callTranscriptBody(_ t: Transcript) -> String {
        let hasThem = t.segments.contains { $0.track == "them" }
        guard hasThem else { return t.plainText.isEmpty ? "_(no speech recognized)_" : t.plainText }
        return t.segments.map { seg in
            let who = seg.track == "mic" ? "**Yo:**" : "**Ellos:**"
            return "\(who) \(seg.text)"
        }.joined(separator: "\n\n")
    }

    private static func notifyRecordingChanged() {
        NotificationCenter.default.post(name: .halleRecordingChanged, object: nil)
    }

    private static func presentAlert(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info; a.runModal()
    }
}
