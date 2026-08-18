import Foundation
import CryptoKit
import AVFoundation

enum BackfillItemState: String, Codable { case pending, snapshotted, transcribing, transcribed, briefing, completed, failed, ambiguous, skipped }

struct HistoricalBackfillItem: Codable, Identifiable {
    var id: UUID
    var slug: String
    var folderPath: String
    var audioFileName: String
    var audioSHA256: String
    var audioBytes: Int64
    var durationSeconds: TimeInterval
    var project: String?
    var priorTranscriptHash: String?
    var priorTranscriptSource: String?
    var estimatedCostUSD: Double
    var state: BackfillItemState
    var deepgramRequestID: String?
    var replacementTranscriptHash: String?
    var briefingHash: String?
    var lastError: String?
    /// Reports are independent of transcription: a briefing failure must not
    /// report the transcript migration as failed, but it must stay visible.
    var briefingCompleted: Bool? = nil
    var briefingError: String? = nil
}

struct HistoricalBackfillManifest: Codable {
    static let schema = "halle.deepgram-backfill.v1"
    var schemaVersion: String
    var createdAt: Date
    var expectedSessionCount: Int
    var expectedDurationSeconds: TimeInterval
    var estimatedCostUSD: Double
    var items: [HistoricalBackfillItem]
    var acceptedABSessionIDs: [UUID]
    var sampleReportsApprovedAt: Date?
    var reconciliationAcceptedAt: Date?
    var rollbackArtifact: BackfillRollbackArtifact?

    /// The authorization in `validateApprovalGate` is bound to this value, so the
    /// encoding must be canonical. A default `JSONEncoder` does not order keys and
    /// produced ~94 different hashes for 500 encodings of one unchanged manifest,
    /// which made the gate reject untampered manifests as "changed after approval".
    var manifestHash: String {
        var copy = self; copy.rollbackArtifact = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(copy)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct BackfillRollbackArtifact: Codable {
    var commit: String
    var tag: String
    var appArchivePath: String
    var appSHA256: String
    var packageInventoryPath: String
    var recordedAt: Date
}

struct HistoricalBackfillAuthorization: Codable {
    var manifestHash: String
    var approvedAt: Date
    var approvedProjectedSpendUSD: Double
    var approvedSessionCount: Int
    var samplesAccepted: Bool
    /// Set only by a deliberate operator act when the manifest no longer matches
    /// the ADR 0004 baseline of 27 recordings / 1,132.5 minutes. It must not be
    /// derived from the manifest, or the variance guards below never fire.
    var acknowledgedBaselineDrift: Bool = false
}

struct HistoricalBackfillReconciliation: Codable {
    var schemaVersion = "halle.deepgram-reconciliation.v1"
    var generatedAt: Date
    var manifestHash: String
    var expected: Int
    var completed: Int
    var skipped: Int
    var ambiguous: Int
    var failed: Int
    var estimatedCostUSD: Double
    var requestIDs: [String]
    var transcriptHashes: [String]
    var briefingHashes: [String]
    /// Recordings whose transcript was promoted but whose report did not
    /// complete. Surfaced separately so it is never mistaken for full success.
    var briefingsIncomplete: Int = 0
}

enum HistoricalBackfillError: Error, LocalizedError {
    case recordingActive, consentRequired, keyRequired, manifestChanged, sampleGateRequired
    case countVariance(actual: Int), durationVariance(actual: TimeInterval), spendApprovalRequired(Double)
    var errorDescription: String? {
        switch self {
        case .recordingActive: "Historical processing cannot run while Hall-e is recording."
        case .consentRequired: "Historical cloud-audio and transcript-text consents are required."
        case .keyRequired: "A rotated Deepgram key is required in Keychain."
        case .manifestChanged: "The historical manifest changed after approval."
        case .sampleGateRequired: "Representative A/B samples and reports must be accepted first."
        case .countVariance(let actual):
            "The ADR baseline is \(HistoricalBackfillController.expectedCount) historical recordings; found \(actual). Acknowledge the drift to proceed."
        case .durationVariance(let actual):
            "Historical duration differs from the ADR baseline by more than 1% (\(Int(actual)) seconds vs \(Int(HistoricalBackfillController.expectedDuration))). Acknowledge the drift to proceed."
        case .spendApprovalRequired(let amount): "Projected historical spend $\(String(format: "%.2f", amount)) requires confirmation."
        }
    }
}

@MainActor enum HistoricalBackfillController {
    /// The ADR 0004 baseline as recorded on 2026-08-09. These are deliberately
    /// not updated to match the current library: their whole purpose is to make
    /// a changed corpus visible and require an explicit acknowledgement.
    static let expectedCount = 27
    static let expectedDuration: TimeInterval = 67_950
    static let approvalCostThreshold = 12.0

    /// Zero-network orientation. It hashes local audio/transcripts and writes no
    /// active recording artifacts.
    static func makeManifest(sessions: [RecordingSession] = RecordingStore.allSessions(),
                             destination: URL? = nil) throws -> URL {
        let items = try sessions.map { session -> HistoricalBackfillItem in
            let audio = session.playbackURL
            let values = try audio.resourceValues(forKeys: [.fileSizeKey])
            let prior = TranscriptStore.load(session)
            let audioFile = try? AVAudioFile(forReading: audio)
            let assetDuration = audioFile.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
            let duration = assetDuration.isFinite && assetDuration > 0
                ? assetDuration : max(0, (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt))
            return .init(id: session.id, slug: session.slug, folderPath: session.folderPath ?? session.slug,
                         audioFileName: audio.lastPathComponent,
                         audioSHA256: try DeepgramTranscriptionProvider.sha256(audio),
                         audioBytes: Int64(values.fileSize ?? 0), durationSeconds: duration,
                         project: session.eventSnapshot?.projectId, priorTranscriptHash: prior?.contentHash,
                         priorTranscriptSource: prior?.source,
                         estimatedCostUSD: DeepgramConfiguration.estimatedCostUSD(duration: duration),
                         state: .pending, deepgramRequestID: nil, replacementTranscriptHash: nil,
                         briefingHash: nil, lastError: nil)
        }.sorted { $0.slug < $1.slug }
        let manifest = HistoricalBackfillManifest(schemaVersion: HistoricalBackfillManifest.schema,
                                                  createdAt: Date(), expectedSessionCount: expectedCount,
                                                  expectedDurationSeconds: expectedDuration,
                                                  estimatedCostUSD: items.reduce(0) { $0 + $1.estimatedCostUSD },
                                                  items: items, acceptedABSessionIDs: [], sampleReportsApprovedAt: nil,
                                                  reconciliationAcceptedAt: nil, rollbackArtifact: nil)
        let url = destination ?? AppPaths.backfillDirectory.appendingPathComponent("deepgram-manifest.json")
        try write(manifest, to: url)
        return url
    }

    static func validateApprovalGate(_ manifest: HistoricalBackfillManifest,
                                     authorization: HistoricalBackfillAuthorization) throws {
        guard !RecordingService.shared.isRecording else { throw HistoricalBackfillError.recordingActive }
        guard AppPreferences.allowCloudAudioTranscription && AppPreferences.allowCloudTranscriptReports else {
            throw HistoricalBackfillError.consentRequired
        }
        guard KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount) else { throw HistoricalBackfillError.keyRequired }
        guard authorization.manifestHash == manifest.manifestHash else { throw HistoricalBackfillError.manifestChanged }
        guard authorization.samplesAccepted, manifest.acceptedABSessionIDs.count >= 4,
              manifest.sampleReportsApprovedAt != nil else { throw HistoricalBackfillError.sampleGateRequired }
        guard authorization.approvedSessionCount == manifest.items.count else {
            throw HistoricalBackfillError.manifestChanged
        }
        guard manifest.items.count == expectedCount || authorization.acknowledgedBaselineDrift else {
            throw HistoricalBackfillError.countVariance(actual: manifest.items.count)
        }
        let duration = manifest.items.reduce(0) { $0 + $1.durationSeconds }
        let variance = abs(duration - expectedDuration) / expectedDuration
        guard variance <= 0.01 || authorization.acknowledgedBaselineDrift else {
            throw HistoricalBackfillError.durationVariance(actual: duration)
        }
        guard manifest.estimatedCostUSD <= approvalCostThreshold ||
                authorization.approvedProjectedSpendUSD >= manifest.estimatedCostUSD else {
            throw HistoricalBackfillError.spendApprovalRequired(manifest.estimatedCostUSD)
        }
    }

    /// Executes serially and checkpoints after every session. The caller must
    /// provide an authorization bound to the exact manifest hash.
    static func run(manifestURL: URL, authorization: HistoricalBackfillAuthorization) async throws {
        var manifest = try loadManifest(manifestURL)
        try validateApprovalGate(manifest, authorization: authorization)
        for index in manifest.items.indices where manifest.items[index].state != .completed {
            guard !RecordingService.shared.isRecording else { throw HistoricalBackfillError.recordingActive }
            guard let session = RecordingStore.allSessions().first(where: { $0.id == manifest.items[index].id }) else {
                manifest.items[index].state = .skipped; manifest.items[index].lastError = "Recording folder is unavailable."
                try write(manifest, to: manifestURL); continue
            }
            try snapshot(session)
            manifest.items[index].state = .transcribing; try write(manifest, to: manifestURL)
            guard let queued = RecordingStore.queueRetranscription(slug: session.slug) else { continue }
            await RecordingCoordinator.transcribeAndMerge(session: queued,
                                                          event: queued.eventSnapshot ?? fallbackEvent(queued))
            guard let finished = RecordingStore.allSessions().first(where: { $0.id == session.id }) else { continue }
            if finished.transcriptionJob?.status == .ambiguousBilling {
                manifest.items[index].state = .ambiguous
            } else if finished.transcriptionJob?.status != .completed {
                manifest.items[index].state = .failed
                manifest.items[index].lastError = finished.transcriptionJob?.lastError
            } else {
                let transcript = TranscriptStore.load(finished)
                manifest.items[index].replacementTranscriptHash = transcript?.contentHash
                manifest.items[index].deepgramRequestID = transcript?.providerMetadata?.requestID
                let briefingURL = finished.folderURL.appendingPathComponent("briefing.v1.json")
                manifest.items[index].briefingHash = try? DeepgramTranscriptionProvider.sha256(briefingURL)
                // The transcript is promoted and durable at this point. Treating a
                // report failure as a migration failure both misreports the work
                // and blocks reconciliation over an artifact that can be regenerated
                // for free from the cached response.
                manifest.items[index].state = .completed
                manifest.items[index].briefingCompleted = finished.briefingJob?.status == .completed
                manifest.items[index].briefingError = finished.briefingJob?.lastError
                manifest.items[index].lastError = nil
            }
            try write(manifest, to: manifestURL)
        }
        let reconciliation = reconcile(manifest)
        let destination = AppPaths.backfillDirectory.appendingPathComponent("deepgram-reconciliation.json")
        try secureWrite(try JSONEncoder().encode(reconciliation), to: destination)
    }

    static func reconcile(_ manifest: HistoricalBackfillManifest) -> HistoricalBackfillReconciliation {
        .init(generatedAt: Date(), manifestHash: manifest.manifestHash, expected: manifest.items.count,
              completed: manifest.items.filter { $0.state == .completed }.count,
              skipped: manifest.items.filter { $0.state == .skipped }.count,
              ambiguous: manifest.items.filter { $0.state == .ambiguous }.count,
              failed: manifest.items.filter { $0.state == .failed }.count,
              estimatedCostUSD: manifest.items.reduce(0) { $0 + $1.estimatedCostUSD },
              requestIDs: manifest.items.compactMap(\.deepgramRequestID),
              transcriptHashes: manifest.items.compactMap(\.replacementTranscriptHash),
              briefingHashes: manifest.items.compactMap(\.briefingHash),
              briefingsIncomplete: manifest.items.filter { $0.state == .completed && $0.briefingCompleted != true }.count)
    }

    static func loadManifest(_ url: URL) throws -> HistoricalBackfillManifest {
        try JSONDecoder().decode(HistoricalBackfillManifest.self, from: Data(contentsOf: url))
    }

    static func recordABApproval(manifestURL: URL, sessionIDs: [UUID], reportsApproved: Bool) throws {
        var manifest = try loadManifest(manifestURL)
        manifest.acceptedABSessionIDs = Array(Set(sessionIDs)).sorted { $0.uuidString < $1.uuidString }
        manifest.sampleReportsApprovedAt = reportsApproved ? Date() : nil
        try write(manifest, to: manifestURL)
    }

    static func makeAuthorization(for manifest: HistoricalBackfillManifest,
                                  approvedSpendUSD: Double, samplesAccepted: Bool,
                                  acknowledgedBaselineDrift: Bool = false) -> HistoricalBackfillAuthorization {
        .init(manifestHash: manifest.manifestHash, approvedAt: Date(),
              approvedProjectedSpendUSD: approvedSpendUSD,
              approvedSessionCount: manifest.items.count, samplesAccepted: samplesAccepted,
              acknowledgedBaselineDrift: acknowledgedBaselineDrift)
    }

    /// True when the manifest no longer matches the ADR 0004 baseline, so the UI
    /// can present the drift for acknowledgement instead of hiding it.
    static func baselineDrift(_ manifest: HistoricalBackfillManifest) -> String? {
        let duration = manifest.items.reduce(0) { $0 + $1.durationSeconds }
        let variance = abs(duration - expectedDuration) / expectedDuration
        guard manifest.items.count != expectedCount || variance > 0.01 else { return nil }
        return "ADR baseline \(expectedCount) recordings / \(Int(expectedDuration / 60)) min · manifest \(manifest.items.count) recordings / \(Int(duration / 60)) min"
    }

    static func acceptReconciliation(manifestURL: URL, rollbackArtifact: BackfillRollbackArtifact) throws {
        var manifest = try loadManifest(manifestURL)
        let reconciliation = reconcile(manifest)
        guard reconciliation.failed == 0, reconciliation.ambiguous == 0,
              reconciliation.completed == reconciliation.expected else {
            throw HistoricalBackfillError.sampleGateRequired
        }
        manifest.reconciliationAcceptedAt = Date()
        manifest.rollbackArtifact = rollbackArtifact
        try write(manifest, to: manifestURL)
    }

    private static func snapshot(_ session: RecordingSession) throws {
        let directory = session.folderURL.appendingPathComponent("pre-deepgram", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: session.transcriptFileURL.path) {
            let target = directory.appendingPathComponent("transcript.json")
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: session.transcriptFileURL, to: target) }
        }
        if let note = session.notePath, let vault = VaultAccess.currentVaultURL() {
            let folder = ObsidianVaultConfig.load()?.subfolderName ?? "Hall-e"
            let relative = note.hasPrefix(folder + "/") ? String(note.dropFirst(folder.count + 1)) : note
            let source = vault.appendingPathComponent(folder).appendingPathComponent(relative)
            let target = directory.appendingPathComponent("meeting-note.md")
            if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func fallbackEvent(_ session: RecordingSession) -> UnifiedEvent {
        UnifiedEvent(dedupKey: session.eventDedupKey, title: session.eventTitle,
                     startTs: session.eventStartAt ?? session.startedAt, endTs: session.endedAt ?? session.startedAt,
                     isAllDay: false, status: "confirmed", effectiveResponse: nil, meetingURL: nil, location: nil,
                     descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                     winnerAccountEmail: AppPreferences.primaryAccountEmail ?? "", projectId: nil,
                     projectConfidence: nil, sourcesJSON: "[]")
    }

    private static func write(_ manifest: HistoricalBackfillManifest, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try secureWrite(try encoder.encode(manifest), to: url)
    }
    private static func secureWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
