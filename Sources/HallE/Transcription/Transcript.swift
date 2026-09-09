import Foundation

struct TranscriptSegment: Codable, Hashable {
    var start: TimeInterval      // offset from recording start (chunk offset applied)
    var duration: TimeInterval
    var text: String
    var track: String            // "mic" | "system"
    /// Deepgram diarization is anonymous. A speaker label is evidence about a
    /// voice cluster, never a person's identity.
    var speaker: Int? = nil
    var speakerConfidence: Double? = nil
}

struct TranscriptWord: Codable, Hashable {
    var word: String
    var punctuatedWord: String?
    var start: TimeInterval
    var end: TimeInterval
    var confidence: Double?
    var speaker: Int?
    var speakerConfidence: Double?
}

struct TranscriptProviderMetadata: Codable, Hashable {
    var provider: String
    var model: String
    var requestID: String?
    var createdAt: Date
    var audioSHA256: String
    var optionsFingerprint: String
    var rawResponseFileName: String?
    /// True when this transcript was normalized from a locally cached response
    /// instead of a new paid request. Optional so older transcripts still decode.
    var reusedCachedResponse: Bool? = nil
    /// Which Deepgram account paid for this transcript: "primary" or "fallback".
    /// Recorded so a switch is auditable after the fact, not just at alert time.
    var credential: String? = nil
}

struct Transcript: Codable {
    var sessionID: UUID
    var localeUsed: String
    var segments: [TranscriptSegment]
    var status: TranscriptStatus
    var source: String           // "sfspeech-on-device"
    var words: [TranscriptWord]? = nil
    var providerMetadata: TranscriptProviderMetadata? = nil

    /// Readable copy/export with stable anonymous voice labels and time offsets.
    /// Keep plainText separate for language-model input and classification.
    var speakerLabeledText: String {
        segments.map { segment in
            let seconds = segment.start.isFinite ? max(0, Int(min(segment.start, 35_999_999))) : 0
            let timestamp = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            let label = segment.speaker.map { "Speaker \($0 + 1)" }
                ?? (segment.track == "mic" ? "Microphone" : "Audio")
            return "[\(timestamp)] \(label): \(segment.text)"
        }.joined(separator: "\n\n")
    }

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }
}
