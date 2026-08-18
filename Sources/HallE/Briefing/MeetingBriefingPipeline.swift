import Foundation

@MainActor enum MeetingBriefingPipeline {
    static func run(session initial: RecordingSession, transcript: Transcript, context: MeetingContext,
                    service: MeetingNoteService, notePath: String,
                    client: OpenClawReportClient = .init(configuration: .init())) async -> RecordingSession {
        var session = initial
        guard AppPreferences.allowCloudTranscriptReports else {
            session.briefingJob = .init(status: .consentBlocked, attemptCount: session.briefingJob?.attemptCount ?? 0,
                                        transcriptHash: transcript.contentHash,
                                        promptVersion: OpenClawReportConfiguration.promptVersion,
                                        model: client.configuration.model,
                                        lastError: "Cloud transcript report consent is disabled.")
            session.save(); return session
        }
        var job = session.briefingJob ?? .init(status: .queued, attemptCount: 0,
                                               transcriptHash: transcript.contentHash,
                                               promptVersion: OpenClawReportConfiguration.promptVersion,
                                               model: client.configuration.model)
        if job.status == .completed, job.transcriptHash == transcript.contentHash,
           FileManager.default.fileExists(atPath: session.folderURL.appendingPathComponent("briefing.v1.json").path) {
            return session
        }
        job.status = .running; job.attemptCount += 1; job.startedAt = Date(); job.lastError = nil
        job.transcriptHash = transcript.contentHash; job.model = client.configuration.model
        session.briefingJob = job; session.save()
        do {
            let briefing = try await client.generate(transcript: transcript, context: context, sessionID: session.id)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonURL = session.folderURL.appendingPathComponent("briefing.v1.json")
            let markdownURL = session.folderURL.appendingPathComponent("briefing.md")
            let pdfURL = session.folderURL.appendingPathComponent("briefing.pdf")
            try secureWrite(encoder.encode(briefing), to: jsonURL)
            let markdown = BriefingRenderer.markdown(briefing)
            try secureWrite(Data(markdown.utf8), to: markdownURL)
            job.status = .rendering; session.briefingJob = job; session.save()
            let (profile, designDirectory) = BriefingDesignProfileStore.load(projectName: context.project, service: service)
            try await BriefingRenderer.renderPDF(briefing, profile: profile,
                                                 designDirectory: designDirectory, destination: pdfURL)
            let writer = VaultWriter(vaultURL: service.vaultURL)
            let paths = VaultPathBuilder(config: service.config)
            try writer.mergeSection(relativePath: notePath, section: "briefing", newContent: markdown,
                                    headingAnchor: "Briefing", mode: .replace, pathBuilder: paths)
            try writer.updateFrontmatter(relativePath: notePath, key: "briefing_path", value: pdfURL.path, pathBuilder: paths)
            try writer.updateFrontmatter(relativePath: notePath, key: "briefing_status", value: "completed", pathBuilder: paths)
            job.status = .completed; job.completedAt = Date(); job.lastError = nil
            session.briefingJob = job; session.save()
        } catch {
            if !AppPreferences.allowCloudTranscriptReports {
                job.status = .consentBlocked
            } else if job.attemptCount < 4 {
                job.status = .queued
            } else {
                job.status = .actionRequired
            }
            job.lastError = sanitize(error)
            session.briefingJob = job; session.save()
            try? VaultWriter(vaultURL: service.vaultURL).updateFrontmatter(
                relativePath: notePath, key: "briefing_status", value: job.status.rawValue,
                pathBuilder: VaultPathBuilder(config: service.config))
            if job.status == .queued {
                let retryAttempt = job.attemptCount
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(min(180, pow(2.0, Double(retryAttempt)) * 5)))
                    await resumeQueuedWhenIdle()
                }
            }
        }
        return session
    }

    static func resumeQueuedWhenIdle() async {
        guard !RecordingService.shared.isRecording, let service = MeetingNoteService.make() else { return }
        for session in RecordingStore.allSessions().filter({ [.queued, .running].contains($0.briefingJob?.status) }) {
            guard !RecordingService.shared.isRecording,
                  let transcript = TranscriptStore.load(session), let notePath = session.notePath else { return }
            let event = session.eventSnapshot
            let context = MeetingContext(title: event?.title ?? session.eventTitle,
                                         project: event?.projectId,
                                         date: HalleDate.day(event?.startTs ?? session.startedAt), attendees: [])
            _ = await run(session: session, transcript: transcript, context: context, service: service, notePath: notePath)
        }
    }

    private static func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func sanitize(_ error: Error) -> String {
        String(error.localizedDescription.replacingOccurrences(of: NSHomeDirectory(), with: "~").prefix(300))
    }
}
