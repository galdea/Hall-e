import Foundation

/// Durable state for a transcription. It deliberately lives beside the
/// recording metadata (rather than in a process-local Task) so a quit, crash,
/// or speech-service interruption can be resumed safely.
enum TranscriptionJobStatus: String, Codable, Equatable {
    case queued
    case running
    case completed
    case retryableFailed = "retryable-failed"
    case actionRequired = "action-required"
    case ambiguousBilling = "ambiguous-billing"
    case consentBlocked = "consent-blocked"
    case cancelled
}

enum TranscriptionTrackStatus: String, Codable, Equatable {
    case queued
    case running
    case completed
    case failed
    case unavailable
}

struct TranscriptionChunkProgress: Codable, Equatable, Hashable, Identifiable {
    var index: Int
    var offset: TimeInterval
    var completed: Bool

    var id: Int { index }
}

struct TranscriptionTrackProgress: Codable, Equatable, Identifiable {
    var track: String
    var fileName: String
    var status: TranscriptionTrackStatus
    var chunks: [TranscriptionChunkProgress]
    var lastError: String?

    var id: String { track }

    var completedChunkIndexes: Set<Int> {
        Set(chunks.filter(\.completed).map(\.index))
    }

    mutating func configureChunks(_ values: [(index: Int, offset: TimeInterval)]) {
        let completed = completedChunkIndexes
        chunks = values.map { TranscriptionChunkProgress(index: $0.index, offset: $0.offset,
                                                           completed: completed.contains($0.index)) }
    }

    mutating func markCompleted(_ index: Int) {
        guard let position = chunks.firstIndex(where: { $0.index == index }) else { return }
        chunks[position].completed = true
    }
}

struct TranscriptionJob: Codable, Equatable {
    var status: TranscriptionJobStatus
    var attemptCount: Int
    var tracks: [TranscriptionTrackProgress]
    var lastError: String?
    var queuedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var cloud: CloudTranscriptionJob?

    init(status: TranscriptionJobStatus = .queued, attemptCount: Int = 0,
         tracks: [TranscriptionTrackProgress] = [], lastError: String? = nil,
         queuedAt: Date = Date(), startedAt: Date? = nil, completedAt: Date? = nil,
         cloud: CloudTranscriptionJob? = nil) {
        self.status = status
        self.attemptCount = attemptCount
        self.tracks = tracks
        self.lastError = lastError
        self.queuedAt = queuedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.cloud = cloud
    }

    static func legacy(status: TranscriptStatus) -> TranscriptionJob {
        switch status {
        case .completed:
            return TranscriptionJob(status: .completed, completedAt: Date())
        case .failed:
            return TranscriptionJob(status: .retryableFailed)
        case .inProgress:
            // A process can never own this job after a relaunch. The store
            // converts it to queued during reconciliation.
            return TranscriptionJob(status: .running, startedAt: Date())
        case .pending:
            return TranscriptionJob(status: .queued)
        }
    }

    mutating func queueForRetry() {
        if CloudFallbackPolicy.requiresReview(cloud) {
            status = .ambiguousBilling
            lastError = "The previous cloud submission has no confirmed outcome. Review the provider job before uploading again."
            return
        }
        let resumableSpeechmatics = cloud?.provider == .speechmatics && cloud?.providerJobID != nil
        status = .queued
        lastError = nil
        queuedAt = Date()
        startedAt = nil
        completedAt = nil
        if resumableSpeechmatics {
            cloud?.state = .awaitingResponse
            cloud?.phase = .polling
        }
        // Retry retains provider routing, region, and any Retry-After deadline.
        // Only an explicit new transcription discards these checkpoints.
        cloud?.updatedAt = Date()
        for index in tracks.indices {
            if tracks[index].status == .failed { tracks[index].status = .queued }
            tracks[index].lastError = nil
        }
    }

    /// A completed job has no useful checkpoints for a different engine or
    /// language. Re-transcription intentionally starts both tracks from zero.
    mutating func resetForRetranscription() {
        status = .queued
        attemptCount = 0
        tracks = []
        lastError = nil
        queuedAt = Date()
        startedAt = nil
        completedAt = nil
        cloud = nil
    }

    mutating func beginAttempt() {
        status = .running
        attemptCount += 1
        startedAt = Date()
        lastError = nil
    }

    /// Automatic recovery respects the provider's backoff even after relaunch.
    func isDueForAutomaticRetry(at now: Date = Date()) -> Bool {
        status == .queued && (cloud?.retryAfter.map { $0 <= now } ?? true)
    }

    mutating func recordUnexpectedFailure(_ message: String) {
        status = CloudFallbackPolicy.requiresReview(cloud) ? .ambiguousBilling : .retryableFailed
        lastError = message
    }
}

enum TranscriptionErrorSanitizer {
    /// Speech and AVFoundation errors sometimes include file URLs or host
    /// details. Keep recovery guidance useful without persisting those details
    /// in a user-visible recording index.
    static func message(_ error: Error) -> String {
        let raw = error.localizedDescription
            .replacingOccurrences(of: AppPaths.recordingsDir.path, with: "this recording")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return "Hall-e could not transcribe this audio." }
        return String(raw.prefix(280))
    }

    static func guidance(for message: String?) -> String {
        let text = (message ?? "").lowercased()
        if text.contains("ambiguous") || text.contains("will not be uploaded again")
            || text.contains("no confirmed outcome") || text.contains("lost the response") {
            return "The recording is safe. Reveal the audio and review the provider job before choosing a new transcription attempt."
        }
        if text.contains("credit") {
            return "Check the balance of the active transcription provider in its dashboard, then retry."
        }
        if text.contains("spend guard") || text.contains("spend limit") {
            return "Review the monthly spending guard in Settings → Transcription, then retry."
        }
        if text.contains("deepgram") {
            return "Check your Deepgram key and audio permission in Settings → Transcription, test the connection, then retry."
        }
        if text.contains("speechmatics") || text.contains("processing region") {
            return "Configure the Speechmatics key, region, Model Training confirmation, and consent in Settings → Transcription, then retry."
        }
        if text.contains("api key") {
            return "Check your selected provider's key in Settings → Transcription, test the connection, then retry."
        }
        if text.contains("authorized") || text.contains("permission") {
            return "Allow Speech Recognition in System Settings, then retry."
        }
        if text.contains("locale") || text.contains("on-device") {
            return "Install an on-device dictation language in System Settings → Keyboard → Dictation, then retry."
        }
        if text.contains("audio") || text.contains("decode") || text.contains("file") {
            return "The audio could not be read. Reveal it, confirm it plays, then retry."
        }
        return "The recording is safe. Check the selected transcription provider and your connection, then retry."
    }
}
