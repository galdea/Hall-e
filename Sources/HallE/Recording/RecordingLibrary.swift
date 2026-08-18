import Foundation

/// Files recordings under their thematic project and gives them a name that
/// says what the meeting was about and who was in it.
///
/// Every operation here moves data; none of it deletes. A move that cannot be
/// completed leaves the recording exactly where it was — an oddly named folder
/// is recoverable, a lost one is not.
@MainActor
enum RecordingLibrary {
    /// Renames and refiles a recording once its transcript exists. The subject
    /// comes from the transcript; the participants come from the calendar and
    /// the people directory, never from the model — attendees are a fact we
    /// already hold, and asking an LLM who spoke invites invented names.
    static func fileByContent(session: RecordingSession, event: UnifiedEvent?,
                              transcript: String) async -> RecordingSession {
        let topic = await topic(for: session, event: event, transcript: transcript)
        return refile(session: session, project: resolveProject(session, explicit: event?.projectId),
                      topic: topic, event: event)
    }

    static func resolveProject(_ session: RecordingSession, explicit: String?) -> String? {
        RecordingProjectResolver.project(for: session, explicit: explicit,
                                         knownProjects: AliasStore.shared.projects.map(\.name))
    }

    /// Moves a recording to `<project>/<name>`, creating the project folder and
    /// stepping around an existing folder of the same name. Returns the session
    /// as it now stands on disk — unchanged if anything went wrong.
    static func refile(session: RecordingSession, project: String?, topic: String?,
                       event: UnifiedEvent? = nil) -> RecordingSession {
        let participants = participantNames(for: session, event: event)
        let baseName = RecordingFolderName.compose(startedAt: session.startedAt, topic: topic,
                                                   fallbackTitle: session.eventTitle,
                                                   participants: participants)
        let folder = RecordingFolderName.projectFolder(project)
        let root = AppPaths.recordingsDir
        let source = session.folderURL

        guard FileManager.default.fileExists(atPath: source.path) else {
            Log.rec.error("cannot refile missing recording folder: \(session.slug, privacy: .public)")
            return session
        }

        var updated = session
        updated.contentTitle = RecordingFolderName.cleanTopic(topic)

        let projectFolder = root.appendingPathComponent(folder, isDirectory: true)
        // The recording's own folder is not a collision with itself.
        let name = uniqueName(baseName) { candidate in
            let path = projectFolder.appendingPathComponent(candidate).path
            return FileManager.default.fileExists(atPath: path) && path != source.path
        }
        let targetPath = "\(folder)/\(name)"
        if targetPath == session.folderPath {
            updated.save()
            return updated
        }

        do {
            try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: projectFolder.path)
            try FileManager.default.moveItem(at: source, to: projectFolder.appendingPathComponent(name))
        } catch {
            // Keep the recording where it is and keep its metadata truthful.
            Log.rec.error("refiling \(session.slug, privacy: .public) failed: \(error, privacy: .public)")
            updated.save()
            return updated
        }

        updated.folderPath = targetPath
        updated.save()
        Log.rec.info("filed recording under \(targetPath, privacy: .public)")
        return updated
    }

    /// One-time move of the flat `Recordings/<slug>` layout into per-project
    /// folders. Deterministic: it uses the calendar title and attendees, so it
    /// never sends a historical transcript anywhere. Transcript-derived titles
    /// for those recordings are a separate, user-initiated pass.
    static func migrateFlatLayoutOnce() {
        guard AppPreferences.recordingLayoutMigration < 1 else { return }
        var moved: [RecordingSession] = []
        var failed = 0
        for session in RecordingStore.allSessions() where session.folderPath == nil {
            let after = refile(session: session, project: resolveProject(session, explicit: nil),
                               topic: nil)
            if after.folderPath == nil { failed += 1 } else { moved.append(after) }
        }
        // Only close the migration when every recording actually moved. A disk
        // or permission problem that stranded some of them must get another go
        // at the next launch, not be recorded as done.
        if failed == 0 {
            AppPreferences.recordingLayoutMigration = 1
        } else {
            Log.rec.error("\(failed, privacy: .public) recording(s) could not be filed; will retry next launch")
        }
        guard !moved.isEmpty else { return }
        Log.rec.info("filed \(moved.count, privacy: .public) recording(s) into project folders")
        NotificationCenter.default.post(name: .halleRecordingChanged, object: nil)
        // Vault writes touch the user's Obsidian folder, possibly on iCloud.
        // The recordings are already safe on disk, so this must not sit in the
        // launch path.
        Task { @MainActor in moved.forEach(updateNoteRecordingPath) }
    }

    /// Re-titles already-transcribed recordings from their transcripts. Sends
    /// each transcript to the configured provider, so it stays behind an
    /// explicit user action rather than running at launch.
    @discardableResult
    static func retitleTranscribedRecordings() async -> Int {
        var renamed = 0
        for session in RecordingStore.allSessions() {
            guard session.transcriptStatus == .completed, session.contentTitle == nil,
                  let transcript = RecordingStore.transcriptText(for: session),
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let after = await fileByContent(session: session, event: session.eventSnapshot,
                                            transcript: transcript)
            if after.contentTitle != nil { renamed += 1 }
            updateNoteRecordingPath(after)
        }
        if renamed > 0 { NotificationCenter.default.post(name: .halleRecordingChanged, object: nil) }
        return renamed
    }

    /// Points the meeting note's `recording_path` at wherever the recording now
    /// lives. A stale absolute path is the one way a move can look like a loss.
    static func updateNoteRecordingPath(_ session: RecordingSession) {
        guard let notePath = session.notePath,
              let config = ObsidianVaultConfig.load(),
              let vaultURL = VaultAccess.currentVaultURL() else { return }
        do {
            try VaultWriter(vaultURL: vaultURL).updateFrontmatter(
                relativePath: notePath, key: "recording_path", value: session.folderURL.path,
                pathBuilder: VaultPathBuilder(config: config))
        } catch {
            Log.rec.warning("recording moved but note link was not updated: \(error, privacy: .public)")
        }
    }

    // MARK: - Inputs

    static func participantNames(for session: RecordingSession, event: UnifiedEvent?) -> [String] {
        let attendees = (event ?? session.eventSnapshot)?.attendees ?? []
        let directory = PeopleStore.shared.people
        return attendees
            .filter { !$0.isSelf && $0.responseStatus != "declined" }
            .compactMap {
                RecordingFolderName.displayName(forEmail: $0.email, calendarName: $0.name,
                                                directory: directory)
            }
    }

    private static func topic(for session: RecordingSession, event: UnifiedEvent?,
                              transcript: String) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let config = LLMProviderConfig.load()
        guard config.useAI, config.allowCloudTranscriptProcessing else {
            Log.ai.info("recording topic skipped (cloud transcript processing off)")
            return nil
        }
        let provider = LLMProviderFactory.make(config: config)
        if provider is DisabledLLMProvider { return nil }
        let context = MeetingContext(title: session.eventTitle,
                                     project: event?.projectId ?? session.eventSnapshot?.projectId,
                                     date: HalleDate.day(session.startedAt),
                                     attendees: (event ?? session.eventSnapshot)?.attendees
                                         .compactMap { $0.email } ?? [])
        do {
            return try await provider.describeMeetingTopic(trimmed, context: context)
        } catch {
            Log.ai.error("recording topic failed, keeping calendar title: \(error, privacy: .public)")
            return nil
        }
    }

    /// Appends ` (2)`, ` (3)`… only when something else already owns the name.
    /// Two meetings can genuinely share a subject and a minute; renaming onto an
    /// existing folder would destroy that recording, so the name gives way.
    nonisolated static func uniqueName(_ base: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(base) else { return base }
        for suffix in 2...50 {
            let candidate = FilenameSanitizer.sanitize("\(base) (\(suffix))",
                                                       maxBytes: RecordingFolderName.maximumNameBytes)
            if !isTaken(candidate) { return candidate }
        }
        return FilenameSanitizer.sanitize("\(base) (\(UUID().uuidString.prefix(8)))",
                                          maxBytes: RecordingFolderName.maximumNameBytes)
    }
}
