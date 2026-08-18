import Foundation

/// Headless driver for the ADR 0004 gates, following the existing
/// `HALLE_DEBUG_*` convention. It exists because the migration is a one-time
/// operator task on a menu-bar app with no scriptable surface, and because the
/// Deepgram key must be written by Hall-E itself: an item added by the `security`
/// CLI carries an ACL that does not trust this app, so the app would prompt or
/// fail when reading it back.
///
/// Every operation is an explicit step. Nothing here runs unless
/// `HALLE_DEEPGRAM_OP` is set, and no step skips a gate — the controller
/// re-validates consent, key, spend, and approval on every call.
@MainActor enum DeepgramMigrationOps {

    static var requestedOperation: String? {
        ProcessInfo.processInfo.environment["HALLE_DEEPGRAM_OP"]
    }

    private static func emit(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static var manifestURL: URL {
        AppPaths.backfillDirectory.appendingPathComponent("deepgram-manifest.json")
    }

    static func run(_ operation: String) async {
        do {
            switch operation {
            case "status": status()
            case "store-key": try storeKey()
            case "store-fallback-key": try storeFallbackKey()
            case "grant-consent": grantConsent()
            case "manifest": try manifest()
            case "select": select()
            case "samples": try await samples()
            case "accept": try accept()
            case "backfill": try await backfill()
            case "test-alert": await testAlert()
            case "balance": await balance()
            default: emit("unknown HALLE_DEEPGRAM_OP=\(operation)")
            }
        } catch {
            emit("FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Setup

    static func status() {
        let key = KeychainStore.get(account: KeychainStore.deepgramTranscriptionAccount)
        emit("engine preference       : \(AppPreferences.transcriptionEngine.rawValue)")
        emit("keychain key            : \(key.map { "present, \($0.count) chars, ends \($0.suffix(4))" } ?? "ABSENT")")
        let fallback = KeychainStore.get(account: KeychainStore.deepgramFallbackTranscriptionAccount)
        emit("fallback key            : \(fallback.map { "present, \($0.count) chars, ends \($0.suffix(4))" } ?? "none")")
        emit("credential order        : \(DeepgramTranscriptionProvider.credentials().map(\.label).joined(separator: " → "))")
        emit("cloud audio consent     : \(AppPreferences.allowCloudAudioTranscription)")
        emit("cloud transcript consent: \(AppPreferences.allowCloudTranscriptReports)")
        emit("monthly spend guard USD : \(AppPreferences.deepgramMonthlyLimitUSD)")
        let resolved = TranscriptionEngineResolver.resolve(
            preference: AppPreferences.transcriptionEngine,
            language: AppPreferences.transcriptionLanguage)
        emit("resolved engine         : \(resolved)")
        emit("recordings on disk      : \(RecordingStore.allSessions().count)")
    }

    /// Stores the key from `HALLE_DEEPGRAM_KEY` and reads it back to prove the
    /// ACL works. The value is never logged in full.
    static func storeKey() throws {
        guard let raw = ProcessInfo.processInfo.environment["HALLE_DEEPGRAM_KEY"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            emit("HALLE_DEEPGRAM_KEY is not set"); return
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainStore.set(key, account: KeychainStore.deepgramTranscriptionAccount)
        guard let readBack = KeychainStore.get(account: KeychainStore.deepgramTranscriptionAccount) else {
            emit("stored but could not be read back — the ACL is wrong"); return
        }
        emit(readBack == key
             ? "stored and read back: \(key.count) chars, ends \(key.suffix(4))"
             : "read-back MISMATCH — stored value differs")
    }

    /// Stores the spare account's key. Kept a separate op from `store-key` so a
    /// slip cannot overwrite the primary with the fallback or vice versa.
    static func storeFallbackKey() throws {
        guard let raw = ProcessInfo.processInfo.environment["HALLE_DEEPGRAM_FALLBACK_KEY"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            emit("HALLE_DEEPGRAM_FALLBACK_KEY is not set"); return
        }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != KeychainStore.get(account: KeychainStore.deepgramTranscriptionAccount) else {
            emit("refused: the fallback key is identical to the primary, which would provide no failover")
            return
        }
        try KeychainStore.set(key, account: KeychainStore.deepgramFallbackTranscriptionAccount)
        guard let readBack = KeychainStore.get(account: KeychainStore.deepgramFallbackTranscriptionAccount) else {
            emit("stored but could not be read back — the ACL is wrong"); return
        }
        emit(readBack == key
             ? "fallback stored and read back: \(key.count) chars, ends \(key.suffix(4))"
             : "read-back MISMATCH — stored value differs")
    }

    /// Records the two consents. ADR 0001 keeps them independent: audio leaving
    /// the Mac is a different decision from transcript text being processed.
    static func grantConsent() {
        AppPreferences.cloudAudioConsent = .grant(
            processor: "Deepgram",
            purpose: "prerecorded meeting transcription and diarization")
        AppPreferences.cloudTranscriptConsent = .grant(
            processor: "OpenClaw + GitHub Copilot/Gemini",
            purpose: "structured meeting briefing generation")
        emit("cloud audio consent     : \(AppPreferences.allowCloudAudioTranscription)")
        emit("cloud transcript consent: \(AppPreferences.allowCloudTranscriptReports)")
        if let consent = AppPreferences.cloudAudioConsent {
            emit("granted at \(ISO8601DateFormatter().string(from: consent.grantedAt)), version \(consent.version), MIP opt-out \(consent.modelImprovementOptOut)")
        }
    }

    /// Proves the credit alert actually reaches Notification Centre, rather than
    /// only proving the decision logic in a unit test.
    static func testAlert() async {
        DeepgramCreditMonitor.resetThrottle()
        let outcome = await DeepgramCreditMonitor.notify(.creditExhausted,
            detail: "Test alert from Hall-e. This is what you will see when the Deepgram account runs out of credit.")
        switch outcome {
        case .posted:
            emit("alert POSTED — check Notification Centre")
        case .throttled:
            emit("alert throttled (already sent within 24h)")
        case .notAuthorized(let detail):
            emit("alert NOT DELIVERED — notifications are not authorized (\(detail)).")
            emit("Grant Hall-e notification permission in System Settings → Notifications, then retry.")
        case .failed(let detail):
            emit("alert FAILED — \(detail)")
        }
        // Give the notification centre a moment before the process exits.
        try? await Task.sleep(for: .seconds(2))
        DeepgramCreditMonitor.resetThrottle()
    }

    static func balance() async {
        if let remaining = await DeepgramCreditMonitor.remainingBalanceUSD() {
            emit("Deepgram balance readable: $\(String(format: "%.2f", remaining))")
        } else {
            emit("Deepgram balance NOT readable — the key lacks the billing:read scope.")
            emit("Alerting falls back to detecting the failed request (HTTP 402 / insufficient credit), which still notifies.")
        }
    }

    // MARK: - Gates

    static func manifest() throws {
        let url = try HistoricalBackfillController.makeManifest()
        let value = try HistoricalBackfillController.loadManifest(url)
        let minutes = value.items.reduce(0) { $0 + $1.durationSeconds } / 60
        emit("manifest: \(url.path)")
        emit("\(value.items.count) recordings · \(String(format: "%.1f", minutes)) min · $\(String(format: "%.2f", value.estimatedCostUSD)) estimated")
        emit("hash: \(value.manifestHash)")
        if let drift = HistoricalBackfillController.baselineDrift(value) {
            emit("BASELINE DRIFT — \(drift). Re-run backfill with HALLE_DEEPGRAM_ACK_DRIFT=1 to acknowledge.")
        }
    }

    static func select() {
        let selections = DeepgramABSampleRunner.selectRepresentatives()
        guard !selections.isEmpty else { emit("no recording has readable audio"); return }
        var total = 0.0
        for selection in selections {
            total += DeepgramConfiguration.estimatedCostUSD(duration: selection.durationSeconds)
            emit("\(selection.category.rawValue) · \(String(format: "%.1f", selection.durationSeconds / 60)) min · \(selection.slug)")
            emit("    proxy: \(selection.selectionProxy)")
        }
        emit("estimated sample cost: $\(String(format: "%.2f", total))")
    }

    static func samples() async throws {
        let selections = DeepgramABSampleRunner.selectRepresentatives()
        guard !selections.isEmpty else { emit("no recording has readable audio"); return }
        emit("transcribing \(selections.count) samples…")
        let report = try await DeepgramABSampleRunner.run(selections: selections)
        for outcome in report.outcomes {
            if outcome.succeeded {
                let confidence = outcome.meanSpeakerConfidence.map { String(format: "%.2f", $0) } ?? "—"
                emit("OK   \(outcome.category.rawValue)")
                emit("     whisper : \(outcome.priorSegmentCount) segments, \(outcome.priorCharacterCount) chars, 0 speakers")
                emit("     deepgram: \(outcome.deepgramSegmentCount) utterances, \(outcome.deepgramCharacterCount) chars, \(outcome.distinctSpeakerCount) speakers, mean speaker confidence \(confidence)")
                emit("     review  : \(outcome.reviewFolderPath)/comparison.md\(outcome.reusedCachedResponse ? "  (reused cached response)" : "")")
            } else {
                emit("FAIL \(outcome.category.rawValue): \(outcome.error ?? "unknown")")
            }
        }
        emit("billed estimate: $\(String(format: "%.2f", report.billedEstimateUSD))")
    }

    static func accept() throws {
        let data = try Data(contentsOf: AppPaths.backfillDirectory.appendingPathComponent("deepgram-ab-samples.json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DeepgramABSampleReport.self, from: data)
        try HistoricalBackfillController.recordABApproval(manifestURL: manifestURL,
                                                          sessionIDs: report.acceptedSessionIDs,
                                                          reportsApproved: true)
        let value = try HistoricalBackfillController.loadManifest(manifestURL)
        emit("accepted \(value.acceptedABSessionIDs.count) A/B sessions; reports approved at \(value.sampleReportsApprovedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—")")
        emit("manifest hash is now \(value.manifestHash) — the authorization binds to this value")
    }

    static func backfill() async throws {
        let value = try HistoricalBackfillController.loadManifest(manifestURL)
        let acknowledge = ProcessInfo.processInfo.environment["HALLE_DEEPGRAM_ACK_DRIFT"] == "1"
        if let drift = HistoricalBackfillController.baselineDrift(value) {
            guard acknowledge else {
                emit("BASELINE DRIFT — \(drift)")
                emit("refusing to run. Set HALLE_DEEPGRAM_ACK_DRIFT=1 to acknowledge.")
                return
            }
            emit("acknowledged drift — \(drift)")
        }
        let authorization = HistoricalBackfillController.makeAuthorization(
            for: value, approvedSpendUSD: value.estimatedCostUSD,
            samplesAccepted: value.sampleReportsApprovedAt != nil,
            acknowledgedBaselineDrift: acknowledge)
        emit("running \(value.items.count) recordings serially · $\(String(format: "%.2f", value.estimatedCostUSD)) estimated…")
        try await HistoricalBackfillController.run(manifestURL: manifestURL, authorization: authorization)
        let reloaded = try HistoricalBackfillController.loadManifest(manifestURL)
        let reconciliation = HistoricalBackfillController.reconcile(reloaded)
        emit("completed \(reconciliation.completed)/\(reconciliation.expected) · failed \(reconciliation.failed) · ambiguous \(reconciliation.ambiguous) · skipped \(reconciliation.skipped)")
        emit("reports incomplete: \(reconciliation.briefingsIncomplete)")
        for item in reloaded.items where item.state != .completed {
            emit("  \(item.state.rawValue): \(item.slug) — \(item.lastError ?? "no detail")")
        }
    }
}
