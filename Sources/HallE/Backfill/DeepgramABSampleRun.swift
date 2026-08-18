import Foundation
import AVFoundation

/// ADR 0004 gate 4: representative A/B samples must be transcribed and accepted
/// before any historical transcript is replaced. This runs Deepgram against a
/// small representative set and writes the results to a review folder only. It
/// never writes `transcript.json`, never touches a transcription job, and never
/// rewrites an Obsidian note, so a rejected sample costs nothing but the request.
enum DeepgramSampleCategory: String, Codable, CaseIterable, Identifiable {
    case cleanSpanish = "clean-spanish"
    case codeSwitched = "code-switched"
    case noisyMultiSpeaker = "noisy-multi-speaker"
    case hardAttribution = "hard-attribution"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cleanSpanish: "Clean Spanish"
        case .codeSwitched: "Spanish/English code-switching"
        case .noisyMultiSpeaker: "Noisy / far-field multi-speaker"
        case .hardAttribution: "Difficult attribution"
        }
    }
}

/// A candidate and the local proxy that selected it. The proxy is an inference
/// from the existing Whisper output and the event snapshot, not a measured
/// property of the audio; it is recorded so the choice stays auditable and can
/// be overridden.
struct DeepgramSampleSelection: Codable, Identifiable {
    var category: DeepgramSampleCategory
    var sessionID: UUID
    var slug: String
    var durationSeconds: TimeInterval
    var selectionProxy: String

    var id: UUID { sessionID }
}

struct DeepgramSampleOutcome: Codable, Identifiable {
    var category: DeepgramSampleCategory
    var sessionID: UUID
    var slug: String
    var durationSeconds: TimeInterval
    var estimatedCostUSD: Double
    var reusedCachedResponse: Bool
    var requestID: String?
    var priorSource: String?
    var priorCharacterCount: Int
    var priorSegmentCount: Int
    var deepgramCharacterCount: Int
    var deepgramSegmentCount: Int
    var distinctSpeakerCount: Int
    var meanSpeakerConfidence: Double?
    var reviewFolderPath: String
    var error: String?

    var id: UUID { sessionID }
    var succeeded: Bool { error == nil }
}

struct DeepgramABSampleReport: Codable {
    static let schema = "halle.deepgram-ab-samples.v1"
    var schemaVersion: String = DeepgramABSampleReport.schema
    var generatedAt: Date
    var outcomes: [DeepgramSampleOutcome]

    var billedEstimateUSD: Double {
        outcomes.filter { $0.succeeded && !$0.reusedCachedResponse }.reduce(0) { $0 + $1.estimatedCostUSD }
    }
    var acceptedSessionIDs: [UUID] { outcomes.filter(\.succeeded).map(\.sessionID) }
}

@MainActor enum DeepgramABSampleRunner {

    /// Shortest recording worth sampling, in seconds.
    static let minimumSampleDuration: TimeInterval = 180

    // MARK: - Selection

    /// `category:substring` pairs, comma separated, pinning a category to a
    /// specific recording when the heuristic picks something unrepresentative.
    nonisolated static func overrides(_ raw: String?) -> [DeepgramSampleCategory: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var result: [DeepgramSampleCategory: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, let category = DeepgramSampleCategory(rawValue: parts[0]),
                  !parts[1].isEmpty else { continue }
            result[category] = parts[1]
        }
        return result
    }

    /// Picks one recording per category using only local evidence. Sessions with
    /// no readable audio are skipped; a category with no remaining candidate is
    /// omitted rather than filled with an arbitrary session.
    static func selectRepresentatives(
        sessions: [RecordingSession] = RecordingStore.allSessions(),
        pinned: [DeepgramSampleCategory: String] = overrides(
            ProcessInfo.processInfo.environment["HALLE_DEEPGRAM_SAMPLE_SLUGS"])
    ) -> [DeepgramSampleSelection] {
        struct Candidate {
            let session: RecordingSession
            let duration: TimeInterval
            let priorText: String
            let attendeeCount: Int
            var charactersPerMinute: Double { duration > 0 ? Double(priorText.count) / (duration / 60) : 0 }
            /// English function words per 1,000 words of the prior transcript. This
            /// must be a rate, not a raw count: a raw count simply scales with
            /// length, which selected the single longest recording in the library
            /// regardless of how much code-switching it actually contained.
            var englishMarkerRate: Double {
                let markers: Set<String> = ["the", "and", "with", "that", "this", "about", "product",
                                            "team", "meeting", "review", "data", "report", "dashboard",
                                            "we", "you", "for", "from", "our", "which", "would"]
                let words = priorText.lowercased().split(whereSeparator: { !$0.isLetter })
                guard words.count >= 200 else { return 0 }
                let hits = words.reduce(into: 0) { $0 += markers.contains(String($1)) ? 1 : 0 }
                return Double(hits) / Double(words.count) * 1000
            }
        }

        let candidates: [Candidate] = sessions.compactMap { session in
            let audio = session.playbackURL
            guard FileManager.default.fileExists(atPath: audio.path) else { return nil }
            let duration = audioDuration(session)
            // A clip too short to contain a real exchange cannot demonstrate
            // sustained accuracy or usable diarization, and characters-per-minute
            // is wildly inflated on a few seconds of dense speech.
            guard duration >= minimumSampleDuration else { return nil }
            let prior = TranscriptStore.load(session)
            return Candidate(session: session, duration: duration,
                             priorText: prior?.plainText ?? "",
                             attendeeCount: session.eventSnapshot?.attendees.count ?? 0)
        }
        guard !candidates.isEmpty else { return [] }

        var chosen: [DeepgramSampleSelection] = []
        var used: Set<UUID> = []

        func take(_ category: DeepgramSampleCategory, _ proxy: String,
                  from pool: [Candidate], by rank: (Candidate, Candidate) -> Bool) {
            var proxy = proxy
            var pool = pool
            // An explicit pin overrides the heuristic and says so in the record.
            if let fragment = pinned[category] {
                let matches = candidates.filter { $0.session.slug.localizedCaseInsensitiveContains(fragment) }
                guard !matches.isEmpty else { return }
                pool = matches
                proxy = "pinned by operator to a recording matching \"\(fragment)\""
            }
            guard let pick = pool.filter({ !used.contains($0.session.id) }).max(by: rank) else { return }
            used.insert(pick.session.id)
            chosen.append(.init(category: category, sessionID: pick.session.id, slug: pick.session.slug,
                                durationSeconds: pick.duration, selectionProxy: proxy))
        }

        // Hardest first, so the strongest signals are not consumed by a weaker
        // category. Whisper producing almost nothing for real audio is the most
        // direct local evidence of an attribution/decode failure.
        take(.hardAttribution,
             "lowest characters-per-minute in the existing Whisper transcript for readable audio",
             from: candidates) { $0.charactersPerMinute > $1.charactersPerMinute }
        take(.codeSwitched,
             "highest English-function-word rate per 1,000 words inside the existing Spanish transcript",
             from: candidates) { $0.englishMarkerRate < $1.englishMarkerRate }
        take(.noisyMultiSpeaker,
             "most calendar attendees, longest recording as tie-break",
             from: candidates) {
            ($0.attendeeCount, $0.duration) < ($1.attendeeCount, $1.duration)
        }
        take(.cleanSpanish,
             "highest characters-per-minute among recordings with at most two attendees",
             from: candidates.filter { $0.attendeeCount <= 2 }) {
            $0.charactersPerMinute < $1.charactersPerMinute
        }
        return chosen.sorted { $0.category.rawValue < $1.category.rawValue }
    }

    static func audioDuration(_ session: RecordingSession) -> TimeInterval {
        let audio = session.playbackURL
        if let file = try? AVAudioFile(forReading: audio) {
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            if seconds.isFinite && seconds > 0 { return seconds }
        }
        return max(0, (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt))
    }

    // MARK: - Run

    /// Transcribes each selection with Deepgram into a review folder. Failures are
    /// recorded per sample; one bad sample does not abort the rest.
    static func run(selections: [DeepgramSampleSelection]) async throws -> DeepgramABSampleReport {
        guard !RecordingService.shared.isRecording else { throw HistoricalBackfillError.recordingActive }
        guard AppPreferences.allowCloudAudioTranscription else { throw HistoricalBackfillError.consentRequired }
        guard KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount) else {
            throw HistoricalBackfillError.keyRequired
        }

        var outcomes: [DeepgramSampleOutcome] = []
        for selection in selections {
            guard !RecordingService.shared.isRecording else { throw HistoricalBackfillError.recordingActive }
            guard let session = RecordingStore.allSessions().first(where: { $0.id == selection.sessionID }) else {
                continue
            }
            outcomes.append(await sample(selection: selection, session: session))
        }
        let report = DeepgramABSampleReport(generatedAt: Date(), outcomes: outcomes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try secureWrite(try encoder.encode(report),
                        to: AppPaths.backfillDirectory.appendingPathComponent("deepgram-ab-samples.json"))
        return report
    }

    private static func sample(selection: DeepgramSampleSelection,
                               session: RecordingSession) async -> DeepgramSampleOutcome {
        let prior = TranscriptStore.load(session)
        let duration = selection.durationSeconds
        let folder = AppPaths.deepgramSampleDirectory
            .appendingPathComponent("\(selection.category.rawValue) - \(session.slug)", isDirectory: true)

        var outcome = DeepgramSampleOutcome(
            category: selection.category, sessionID: session.id, slug: session.slug,
            durationSeconds: duration,
            estimatedCostUSD: DeepgramConfiguration.estimatedCostUSD(duration: duration),
            reusedCachedResponse: false, requestID: nil,
            priorSource: prior?.source, priorCharacterCount: prior?.plainText.count ?? 0,
            priorSegmentCount: prior?.segments.count ?? 0,
            deepgramCharacterCount: 0, deepgramSegmentCount: 0, distinctSpeakerCount: 0,
            meanSpeakerConfidence: nil, reviewFolderPath: folder.path, error: nil)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)

            let provider = DeepgramTranscriptionProvider(configuration: .init(),
                                                         rawResponseDirectory: folder,
                                                         duration: duration,
                                                         responseCache: AppPaths.deepgramResponseCacheDir)
            let transcript = try await provider.transcribe(fileURL: session.playbackURL,
                                                           sessionID: session.id, track: "mixed")

            let speakers = Set(transcript.segments.compactMap(\.speaker))
            let confidences = transcript.segments.compactMap(\.speakerConfidence)
            outcome.reusedCachedResponse = transcript.providerMetadata?.reusedCachedResponse ?? false
            outcome.requestID = transcript.providerMetadata?.requestID
            outcome.deepgramCharacterCount = transcript.plainText.count
            outcome.deepgramSegmentCount = transcript.segments.count
            outcome.distinctSpeakerCount = speakers.count
            outcome.meanSpeakerConfidence = confidences.isEmpty
                ? nil : confidences.reduce(0, +) / Double(confidences.count)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try secureWrite(try encoder.encode(transcript),
                            to: folder.appendingPathComponent("deepgram-transcript.json"))
            try secureWrite(Data(comparison(outcome: outcome, prior: prior, replacement: transcript,
                                            selection: selection).utf8),
                            to: folder.appendingPathComponent("comparison.md"))
        } catch {
            outcome.error = error.localizedDescription
        }
        return outcome
    }

    // MARK: - Review artifact

    /// A side-by-side a person can actually read. Deepgram's speaker numbers are
    /// anonymous voice clusters, so they are rendered as `Speaker N` with no
    /// attempt to attach a name.
    static func comparison(outcome: DeepgramSampleOutcome, prior: Transcript?,
                           replacement: Transcript, selection: DeepgramSampleSelection) -> String {
        let minutes = outcome.durationSeconds / 60
        var lines: [String] = []
        lines.append("# A/B sample — \(selection.category.displayName)")
        lines.append("")
        lines.append("Recording: `\(outcome.slug)`  ")
        lines.append("Duration: \(String(format: "%.1f", minutes)) min  ")
        lines.append("Selected because: \(selection.selectionProxy)  ")
        lines.append("Request: \(outcome.requestID ?? "—")\(outcome.reusedCachedResponse ? " (reused cached response — not billed again)" : "")")
        lines.append("")
        lines.append("| | Whisper (current) | Deepgram nova-3 |")
        lines.append("|---|---|---|")
        lines.append("| Source | `\(outcome.priorSource ?? "—")` | `deepgram:\(DeepgramConfiguration.model)` |")
        lines.append("| Characters | \(outcome.priorCharacterCount) | \(outcome.deepgramCharacterCount) |")
        lines.append("| Segments | \(outcome.priorSegmentCount) | \(outcome.deepgramSegmentCount) |")
        lines.append("| Distinct speakers | \(Set((prior?.segments ?? []).compactMap(\.speaker)).count) | \(outcome.distinctSpeakerCount) |")
        lines.append("| Word timings | \(prior?.words?.isEmpty == false ? "yes" : "no") | \(replacement.words?.isEmpty == false ? "yes" : "no") |")
        let confidence = outcome.meanSpeakerConfidence.map { String(format: "%.2f", $0) } ?? "—"
        lines.append("| Mean speaker confidence | — | \(confidence) |")
        lines.append("")
        lines.append("Check names, numbers, and dates against your memory of the meeting, and confirm the speaker split is usable. Speaker numbers are anonymous voice clusters, not identities.")
        lines.append("")
        lines.append("## Deepgram, first 60 utterances")
        lines.append("")
        for segment in replacement.segments.prefix(60) {
            let speaker = segment.speaker.map { "Speaker \($0)" } ?? segment.track
            lines.append("- `\(timestamp(segment.start))` **\(speaker)** — \(segment.text)")
        }
        lines.append("")
        lines.append("## Whisper, first 60 segments (no speaker separation)")
        lines.append("")
        for segment in (prior?.segments ?? []).prefix(60) {
            lines.append("- `\(timestamp(segment.start))` \(segment.text)")
        }
        if (prior?.segments ?? []).isEmpty {
            lines.append("- _(the existing transcript is empty)_")
        }
        lines.append("")
        lines.append("## Full Deepgram transcript")
        lines.append("")
        var currentSpeaker: Int?
        for segment in replacement.segments {
            if segment.speaker != currentSpeaker {
                currentSpeaker = segment.speaker
                lines.append("")
                lines.append("**\(segment.speaker.map { "Speaker \($0)" } ?? segment.track)**")
            }
            lines.append(segment.text)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
