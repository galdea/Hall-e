import Foundation

/// Reads recording sessions from disk (there's no DB table for them) so the UI
/// can show a per-meeting transcript button keyed by the event's dedupKey.
///
/// Recordings are kept indefinitely. Nothing in Hall-e expires, rotates, or
/// prunes them: the only removal path is `RecordingDeletionService`, driven by
/// an explicit user action. Anything added here that deletes audio on the
/// app's own initiative breaks that guarantee.
enum RecordingStore {
    enum DeletionError: LocalizedError {
        case invalidRecordingFolder

        var errorDescription: String? {
            "Hall-e refused to delete a folder outside its recordings directory."
        }
    }

    static func allSessions() -> [RecordingSession] {
        sessions(in: AppPaths.recordingsDir)
    }

    /// Recordings sit one level deep, inside their thematic project folder.
    /// The root is still read directly so recordings from the flat layout — or
    /// from a migration that was interrupted halfway — stay visible instead of
    /// silently disappearing from the UI.
    static func sessions(in root: URL) -> [RecordingSession] {
        directories(in: root).flatMap { entry -> [RecordingSession] in
            if let session = session(inFolder: entry) { return [session] }
            return directories(in: entry).compactMap(session(inFolder:))
        }
    }

    private static func directories(in url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func session(inFolder folder: URL) -> RecordingSession? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else { return nil }
        return try? JSONDecoder().decode(RecordingSession.self, from: data)
    }

    /// Latest session per event (by start time).
    static func latestByEvent() -> [String: RecordingSession] {
        var map: [String: RecordingSession] = [:]
        for s in allSessions() {
            if let existing = map[s.eventDedupKey], existing.startedAt >= s.startedAt { continue }
            map[s.eventDedupKey] = s
        }
        return map
    }

    static func allSessions(for eventDedupKey: String) -> [RecordingSession] {
        allSessions().filter { $0.eventDedupKey == eventDedupKey }
            .sorted { $0.startedAt > $1.startedAt }
    }

    static func transcriptText(for session: RecordingSession) -> String? {
        TranscriptStore.load(session)?.plainText
    }

    static func delete(_ session: RecordingSession) throws {
        try deleteSessionFolder(relativePath: session.folderPath ?? session.slug,
                                recordingsDirectory: AppPaths.recordingsDir)
    }

    /// Deletes exactly one recording folder. Now that recordings are nested a
    /// level deeper, the old "parent must be the root" guard would have to be
    /// relaxed — so the check is instead that the target sits one or two levels
    /// under the root *and* holds a `session.json`. Without the second half, a
    /// bad relative path could take out a whole project folder.
    static func deleteSessionFolder(relativePath: String, recordingsDirectory: URL) throws {
        let root = recordingsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = root
        for part in relativePath.split(separator: "/") { candidate.appendPathComponent(String(part)) }
        let target = candidate.standardizedFileURL.resolvingSymlinksInPath()

        let rootParts = root.pathComponents
        let targetParts = target.pathComponents
        let depth = targetParts.count - rootParts.count
        guard depth == 1 || depth == 2, Array(targetParts.prefix(rootParts.count)) == rootParts else {
            throw DeletionError.invalidRecordingFolder
        }
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        guard FileManager.default.fileExists(
            atPath: target.appendingPathComponent("session.json").path) else {
            throw DeletionError.invalidRecordingFolder
        }
        try FileManager.default.removeItem(at: target)
    }

    /// Called once at launch: an in-flight transcription cannot still own the
    /// Speech request after Hall-e quits. Queue it for resume, retaining all
    /// completed chunk checkpoints rather than turning it into a generic error.
    static func reconcileStaleTranscripts() {
        for var session in allSessions() {
            var job = session.transcriptionJob ?? .legacy(status: session.transcriptStatus)
            guard job.status == .running || session.transcriptStatus == .inProgress else { continue }
            if job.cloud?.provider == .speechmatics,
               job.cloud?.phase == .submitting,
               job.cloud?.providerJobID == nil {
                job.status = .ambiguousBilling
                job.lastError = "Speechmatics may have accepted the audio before Hall-e quit, but no job ID was saved. The audio will not be uploaded again automatically."
                job.cloud?.state = .ambiguousBilling
                job.cloud?.phase = .ambiguousSubmission
                job.cloud?.updatedAt = Date()
                session.transcriptionJob = job
                session.transcriptStatus = .failed
                session.save()
                Log.rec.error("speechmatics submission became ambiguous after interruption: \(session.slug, privacy: .public)")
                continue
            }
            job.status = .queued
            job.startedAt = nil
            job.lastError = nil
            for index in job.tracks.indices where job.tracks[index].status == .running {
                job.tracks[index].status = .queued
            }
            session.transcriptionJob = job
            session.transcriptStatus = .pending
            session.save()
            Log.rec.info("queued interrupted transcription for resume: \(session.slug, privacy: .public)")
        }
    }

    /// Migration for recordings created before durable jobs. Failed recordings
    /// get exactly one idle retry after upgrade; later retries remain user-led.
    static func enqueueLegacyFailuresForRetryOnce() {
        guard AppPreferences.transcriptionRecoveryMigration < 1 else { return }
        for var session in allSessions() where session.transcriptStatus == .failed {
            var job = session.transcriptionJob ?? .legacy(status: .failed)
            job.queueForRetry()
            session.transcriptionJob = job
            session.transcriptStatus = job.status == .queued ? .pending : .failed
            session.save()
        }
        AppPreferences.transcriptionRecoveryMigration = 1
    }

    /// Retire the old engine-replacement migration. Completed local transcripts
    /// are valid user data; upgrading must not remove them or trigger uploads.
    static func enqueueAppleSpeechFallbacksForRetryOnce() {
        guard AppPreferences.transcriptionRecoveryMigration < 2 else { return }
        AppPreferences.transcriptionRecoveryMigration = 2
    }

    static func queuedSessions() -> [RecordingSession] {
        allSessions().filter {
            let job = $0.transcriptionJob ?? .legacy(status: $0.transcriptStatus)
            return job.status == .queued
        // Recover the newest meeting first so a just-finished call is not
        // hidden behind an older, potentially hours-long recording.
        }.sorted { $0.startedAt > $1.startedAt }
    }

    @discardableResult
    static func queueRetry(slug: String) -> RecordingSession? {
        guard var session = allSessions().first(where: { $0.slug == slug }) else { return nil }
        var job = session.transcriptionJob ?? .legacy(status: session.transcriptStatus)
        job.queueForRetry()
        guard job.status == .queued else {
            session.transcriptionJob = job
            session.transcriptStatus = .failed
            session.save()
            return nil
        }
        session.transcriptionJob = job
        session.transcriptStatus = .pending
        session.save()
        return session
    }

    @discardableResult
    static func queueRetranscription(slug: String) -> RecordingSession? {
        guard var session = allSessions().first(where: { $0.slug == slug }) else { return nil }
        var job = session.transcriptionJob ?? .legacy(status: session.transcriptStatus)
        job.resetForRetranscription()
        session.transcriptionJob = job
        session.transcriptStatus = .pending
        session.localeUsed = nil
        // Keep the active transcript until a replacement validates and is
        // atomically promoted. A failed cloud request must never erase the last
        // usable local result.
        session.save()
        return session
    }
}
