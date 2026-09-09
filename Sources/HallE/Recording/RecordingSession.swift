import Foundation

enum RecordingState: Codable, Equatable {
    case idle, preparing, recording, stopping, completed
    case failed(String)
}

enum TranscriptStatus: String, Codable {
    case pending, inProgress, completed, failed
}

enum RecordingSourceKind: String, Codable {
    case calendarMeeting, whatsAppCall, chromeCall, zoomCall, manual
}

enum RecordingStopReason: String, Codable {
    case manual, scheduledEnd, sourceEnded, silencePrompt, recorderFinished, recorderFailed
}

/// Metadata for one recording, linked to a unified event and its Obsidian note.
struct RecordingSession: Codable, Identifiable {
    let id: UUID
    let eventDedupKey: String
    let eventTitle: String
    var notePath: String?          // vault-relative note this attaches to
    var micFileName: String        // relative to the session folder
    var systemAudioFileName: String?
    var startedAt: Date
    var endedAt: Date?
    var state: RecordingState
    var transcriptStatus: TranscriptStatus
    var localeUsed: String?
    var eventStartAt: Date?
    var scheduledEndAt: Date?
    var sourceKind: RecordingSourceKind?
    var stopReason: RecordingStopReason?
    var playbackFileName: String?
    var systemAudioStartedAt: Date?
    /// When the mic recorder actually began capturing — later than `startedAt`,
    /// which is stamped before the mic-permission prompt. Optional for sessions
    /// saved by older builds.
    var micStartedAt: Date?
    /// Durable checkpoint state for local/on-device transcription. Optional so
    /// recordings written by Hall-e versions before job persistence still load.
    var transcriptionJob: TranscriptionJob?
    /// Report generation is independent from transcription: a report failure
    /// never changes a completed transcript back to failed.
    var briefingJob: BriefingJob?
    /// A snapshot makes retry-after-relaunch independent of a later calendar
    /// refresh. It is particularly important for Hall-e-only local call events.
    var eventSnapshot: UnifiedEvent?
    /// Exact normalized call identity that started this capture, if any. A call
    /// end/tab-close signal only stops a recording with this same identity.
    var callIdentityKey: String?
    var localCaptureEventID: String?
    /// Non-fatal capture limitation, e.g. system-audio permission unavailable.
    var audioCaptureNotice: String?
    /// This recording's folder relative to `AppPaths.recordingsDir`, e.g.
    /// `Accurate/2026-08-04 1801 - Revisión de resultados - Sebastián`.
    /// Recordings are filed under their thematic project and renamed once the
    /// transcript reveals the subject, so the location cannot be derived from
    /// `slug`. Nil for recordings written before the per-project layout, which
    /// still live flat at the root under their slug.
    var folderPath: String?
    /// Transcript-derived subject used in the folder name. Recorded so a second
    /// pass can tell "never titled" from "titled, and this is what we chose".
    var contentTitle: String?

    /// …/Application Support/Hall-e/Recordings/<project>/<name>/
    var folderURL: URL {
        var url = AppPaths.recordingsDir
        for part in (folderPath ?? slug).split(separator: "/") where part != "." && part != ".." {
            url.appendPathComponent(String(part))
        }
        return url
    }
    var micURL: URL { folderURL.appendingPathComponent(micFileName) }
    var systemAudioURL: URL { folderURL.appendingPathComponent(systemAudioFileName ?? "system.m4a") }
    var sessionFileURL: URL { folderURL.appendingPathComponent("session.json") }
    var transcriptFileURL: URL { folderURL.appendingPathComponent("transcript.json") }
    var playbackURL: URL {
        if let playbackFileName {
            let candidate = folderURL.appendingPathComponent(playbackFileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return micURL
    }
    var hasPlayableAudio: Bool { FileManager.default.fileExists(atPath: playbackURL.path) }

    /// The capture is over and its artifacts are on disk. The UI keys playback
    /// and transcript controls off this rather than the meeting's scheduled end,
    /// so a manually stopped recording is reachable immediately instead of
    /// looking deleted for the remainder of the booked slot.
    var isFinished: Bool {
        if endedAt != nil { return true }
        switch state {
        case .completed, .failed: return true
        case .idle, .preparing, .recording, .stopping: return false
        }
    }

    let slug: String

    init(event: UnifiedEvent, notePath: String?, sourceKind: RecordingSourceKind = .calendarMeeting) {
        id = UUID()
        eventDedupKey = event.dedupKey
        eventTitle = event.title
        self.notePath = notePath
        micFileName = "mic.m4a"
        systemAudioFileName = nil
        startedAt = Date()
        endedAt = nil
        state = .idle
        transcriptStatus = .pending
        eventStartAt = event.startTs
        scheduledEndAt = event.endTs > Date() ? event.endTs : nil
        self.sourceKind = sourceKind
        stopReason = nil
        playbackFileName = nil
        systemAudioStartedAt = nil
        micStartedAt = nil
        transcriptionJob = TranscriptionJob()
        briefingJob = nil
        eventSnapshot = event
        callIdentityKey = nil
        localCaptureEventID = nil
        audioCaptureNotice = nil
        let stamp = HalleDate.day(startedAt) + "-" + HalleDate.time(startedAt).replacingOccurrences(of: ":", with: "")
        slug = "\(stamp)-\(FilenameSanitizer.sanitize(event.title, maxBytes: 40))-\(id.uuidString)"
        // File it under the project straight away so a recording is never
        // stranded at the root if titling later fails. The descriptive rename
        // happens once there is a transcript to describe.
        folderPath = "\(RecordingFolderName.projectFolder(event.projectId))/\(slug)"
        contentTitle = nil
    }

    func save() {
        do {
            try persist()
        } catch {
            Log.rec.error("session save failed for \(slug, privacy: .public): \(error, privacy: .public)")
        }
    }

    func persist() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folderURL.path)
        try JSONEncoder().encode(self).write(to: sessionFileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionFileURL.path)
    }
}
