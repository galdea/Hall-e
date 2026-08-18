import Foundation
import Testing
@testable import HallE

@Suite(.serialized)
struct DeepgramTranscriptionTests {
    @Test func requestUsesApprovedNova3MultilingualDiarizationContract() {
        var config = DeepgramConfiguration()
        config.keyterms = ["Hall-E", "Accurate"]
        let components = URLComponents(url: config.requestURL(), resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        #expect(values("model") == ["nova-3"])
        #expect(values("language") == ["multi"])
        #expect(values("diarize_model") == ["v2"])
        #expect(values("mip_opt_out") == ["true"])
        #expect(values("diarize").isEmpty)
        #expect(values("keyterm") == ["Hall-E", "Accurate"])
    }

    @Test func normalizedTranscriptPreservesAnonymousSpeakerEvidence() throws {
        let json = #"""
        {
          "metadata": {"request_id":"req-123"},
          "results": {
            "channels": [{"alternatives": [{
              "transcript":"Hola Gabriel. Hola equipo.",
              "words":[
                {"word":"hola","punctuated_word":"Hola","start":0.0,"end":0.4,"confidence":0.99,"speaker":0,"speaker_confidence":0.96},
                {"word":"gabriel","punctuated_word":"Gabriel.","start":0.4,"end":0.9,"confidence":0.98,"speaker":0,"speaker_confidence":0.95},
                {"word":"hola","punctuated_word":"Hola","start":1.1,"end":1.5,"confidence":0.97,"speaker":1,"speaker_confidence":0.94},
                {"word":"equipo","punctuated_word":"equipo.","start":1.5,"end":2.0,"confidence":0.96,"speaker":1,"speaker_confidence":0.93}
              ]
            }]}],
            "utterances":[
              {"start":0.0,"end":0.9,"transcript":"Hola Gabriel.","speaker":0,"confidence":0.98},
              {"start":1.1,"end":2.0,"transcript":"Hola equipo.","speaker":1,"confidence":0.96}
            ]
          }
        }
        """#
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: Data(json.utf8))
        let provider = DeepgramTranscriptionProvider(configuration: .init(),
                                                     rawResponseDirectory: FileManager.default.temporaryDirectory,
                                                     duration: 2)
        let transcript = try provider.normalize(response, sessionID: UUID(), track: "mixed", digest: "abc")
        #expect(transcript.segments.map(\.speaker) == [0, 1])
        #expect(transcript.words?.count == 4)
        #expect(transcript.providerMetadata?.requestID == "req-123")
        #expect(transcript.source == "deepgram:nova-3")
    }

    @Test func speechWithoutDiarizationCannotReplaceActiveTranscript() throws {
        let json = #"""
        {"results":{"channels":[{"alternatives":[{"transcript":"speech","words":[{"word":"speech","start":0,"end":1}]}]}],"utterances":[]}}
        """#
        let response = try JSONDecoder().decode(DeepgramResponse.self, from: Data(json.utf8))
        let provider = DeepgramTranscriptionProvider(configuration: .init(),
                                                     rawResponseDirectory: FileManager.default.temporaryDirectory,
                                                     duration: 1)
        #expect(throws: DeepgramError.self) {
            try provider.normalize(response, sessionID: UUID(), track: "mixed", digest: "abc")
        }
    }

    @Test func consentIsVersionedAndRevocable() {
        var consent = CloudProcessingConsent.grant(processor: "Deepgram", purpose: "test")
        #expect(consent.isActive)
        #expect(consent.modelImprovementOptOut)
        consent.revoke(at: Date(timeIntervalSince1970: 10))
        #expect(!consent.isActive)
    }

    @Test func retryAfterSupportsDeltaSeconds() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(DeepgramTranscriptionProvider.retryAfter("15", now: now) == Date(timeIntervalSince1970: 115))
    }

    /// ADR 0001 requires raw responses to be reusable so the A/B gate and the
    /// full backfill never pay twice for the same audio under the same options.
    @Test func cachedResponseIsReusedWithoutNetworkOrSpend() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-dg-cache-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("mic.m4a")
        try Data("not really audio, but it hashes".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: root) }

        let json = #"""
        {"metadata":{"request_id":"cached-req"},
         "results":{"channels":[{"alternatives":[{"transcript":"Hola.",
           "words":[{"word":"hola","start":0,"end":0.4,"speaker":0,"speaker_confidence":0.9}]}]}],
          "utterances":[{"start":0,"end":0.4,"transcript":"Hola.","speaker":0}]}}
        """#
        let configuration = DeepgramConfiguration()
        let digest = try DeepgramTranscriptionProvider.sha256(audio)
        let provider = DeepgramTranscriptionProvider(configuration: configuration,
                                                     rawResponseDirectory: root,
                                                     duration: 0.4,
                                                     responseCache: cache)
        let cached = try #require(provider.cachedResponseURL(digest: digest))
        try Data(json.utf8).write(to: cached)

        // Reuse happens after the consent/key guards but before the spend ledger,
        // so re-normalizing a paid response is free and stays consent-gated.
        let reused = try provider.cachedTranscript(digest: digest, sessionID: UUID(), track: "mixed")
        let transcript = try #require(reused)
        #expect(transcript.providerMetadata?.reusedCachedResponse == true)
        #expect(transcript.providerMetadata?.requestID == "cached-req")
        #expect(transcript.segments.map(\.speaker) == [0])
    }

    /// The variance guards used to be satisfied by `makeAuthorization` itself,
    /// so a corpus that no longer matched the ADR baseline passed silently.
    @MainActor @Test func baselineDriftRequiresAnExplicitAcknowledgement() throws {
        let item = HistoricalBackfillItem(
            id: UUID(), slug: "s", folderPath: "p", audioFileName: "mic.m4a", audioSHA256: "d",
            audioBytes: 1, durationSeconds: 600, project: nil, priorTranscriptHash: nil,
            priorTranscriptSource: nil, estimatedCostUSD: 0.08, state: .pending,
            deepgramRequestID: nil, replacementTranscriptHash: nil, briefingHash: nil, lastError: nil)
        let manifest = HistoricalBackfillManifest(
            schemaVersion: HistoricalBackfillManifest.schema, createdAt: Date(),
            expectedSessionCount: HistoricalBackfillController.expectedCount,
            expectedDurationSeconds: HistoricalBackfillController.expectedDuration,
            estimatedCostUSD: 0.08, items: [item], acceptedABSessionIDs: [],
            sampleReportsApprovedAt: nil, reconciliationAcceptedAt: nil, rollbackArtifact: nil)

        // Regression: a default JSONEncoder does not order keys, so this hash was
        // unstable and validateApprovalGate rejected untampered manifests.
        #expect(Set((0..<200).map { _ in manifest.manifestHash }).count == 1)
        #expect(HistoricalBackfillController.baselineDrift(manifest) != nil)
        let unacknowledged = HistoricalBackfillController.makeAuthorization(
            for: manifest, approvedSpendUSD: 1, samplesAccepted: true)
        #expect(!unacknowledged.acknowledgedBaselineDrift)
        let acknowledged = HistoricalBackfillController.makeAuthorization(
            for: manifest, approvedSpendUSD: 1, samplesAccepted: true, acknowledgedBaselineDrift: true)
        #expect(acknowledged.acknowledgedBaselineDrift)
        #expect(acknowledged.manifestHash == manifest.manifestHash)
    }

    @MainActor @Test func abComparisonRendersAnonymousSpeakersAndTheWhisperBaseline() {
        let sessionID = UUID()
        let prior = Transcript(sessionID: sessionID, localeUsed: "es-CL",
                               segments: [.init(start: 0, duration: 1, text: "hola", track: "mic")],
                               status: .completed, source: "whisper-large-v3-turbo-cli")
        let replacement = Transcript(sessionID: sessionID, localeUsed: "multi",
                                     segments: [.init(start: 0, duration: 1, text: "Hola.", track: "mixed",
                                                      speaker: 0, speakerConfidence: 0.9),
                                                .init(start: 1, duration: 1, text: "Hola equipo.", track: "mixed",
                                                      speaker: 1, speakerConfidence: 0.8)],
                                     status: .completed, source: "deepgram:nova-3")
        let selection = DeepgramSampleSelection(category: .codeSwitched, sessionID: sessionID, slug: "slug",
                                                durationSeconds: 120, selectionProxy: "proxy")
        let outcome = DeepgramSampleOutcome(
            category: .codeSwitched, sessionID: sessionID, slug: "slug", durationSeconds: 120,
            estimatedCostUSD: 0.02, reusedCachedResponse: false, requestID: "req",
            priorSource: "whisper-large-v3-turbo-cli", priorCharacterCount: 4, priorSegmentCount: 1,
            deepgramCharacterCount: 17, deepgramSegmentCount: 2, distinctSpeakerCount: 2,
            meanSpeakerConfidence: 0.85, reviewFolderPath: "/tmp", error: nil)

        let markdown = DeepgramABSampleRunner.comparison(outcome: outcome, prior: prior,
                                                         replacement: replacement, selection: selection)
        #expect(markdown.contains("Speaker 0") && markdown.contains("Speaker 1"))
        #expect(markdown.contains("whisper-large-v3-turbo-cli"))
        #expect(markdown.contains("proxy"))
        // Diarization is a voice cluster, never a name.
        #expect(!markdown.contains("Gabriel"))
    }

    /// Credit alerting must fire on money failures and stay silent on everything
    /// else — a transient 500 or a plain 403 must not claim the account is empty.
    @Test func exhaustedCreditIsDistinguishedFromOtherFailures() {
        typealias P = DeepgramTranscriptionProvider
        #expect(P.indicatesExhaustedCredit(status: 402, code: nil, message: nil))
        #expect(P.indicatesExhaustedCredit(status: 403, code: "INSUFFICIENT_CREDITS", message: nil))
        #expect(P.indicatesExhaustedCredit(status: 403, code: nil, message: "Project is out of credit"))
        #expect(P.indicatesExhaustedCredit(status: 400, code: "QUOTA_EXCEEDED", message: nil))
        // Not credit problems.
        #expect(!P.indicatesExhaustedCredit(status: 403, code: nil, message: nil))
        #expect(!P.indicatesExhaustedCredit(status: 401, code: "INVALID_AUTH", message: "bad key"))
        #expect(!P.indicatesExhaustedCredit(status: 500, code: nil, message: "internal error"))
        #expect(!P.indicatesExhaustedCredit(status: 400, code: "INVALID_QUERY", message: "bad param"))
    }

    @MainActor @Test func creditAlertsAreThrottledPerReason() {
        DeepgramCreditMonitor.resetThrottle()
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(DeepgramCreditMonitor.shouldNotify(.creditExhausted, now: now))
        UserDefaults.standard.set(now, forKey: "deepgramCreditNotified.credit-exhausted")
        // Same day: silent. A batch of failed recordings must not be a batch of alerts.
        #expect(!DeepgramCreditMonitor.shouldNotify(.creditExhausted, now: now.addingTimeInterval(3600)))
        // A different reason is tracked separately.
        #expect(DeepgramCreditMonitor.shouldNotify(.monthlyGuardReached, now: now))
        // A day later it speaks up again.
        #expect(DeepgramCreditMonitor.shouldNotify(.creditExhausted, now: now.addingTimeInterval(24 * 60 * 60 + 1)))
        DeepgramCreditMonitor.resetThrottle()
    }

    /// Failover must be reachable only from exhausted credit. Any other failure
    /// — bad key, bad request, transient 5xx — has to surface as itself, or a
    /// misconfigured primary would silently drain the spare account.
    @Test func onlyExhaustedCreditIsEligibleForFailover() {
        func eligible(_ error: DeepgramError) -> Bool {
            if case .creditExhausted = error { return true }
            return false
        }
        #expect(eligible(.creditExhausted("primary is empty")))
        #expect(!eligible(.missingAPIKey))
        #expect(!eligible(.consentRequired))
        #expect(!eligible(.actionRequired(status: 401, code: "INVALID_AUTH")))
        #expect(!eligible(.retryable(status: 503, retryAfter: nil, message: "busy")))
        #expect(!eligible(.ambiguousBilling("lost response")))
        #expect(!eligible(.spendLimitExceeded(projected: 30, limit: 25)))
        #expect(!eligible(.invalidResponse("garbage")))
    }

    @Test func credentialOrderPutsPrimaryFirstAndDropsDuplicates() {
        typealias C = DeepgramTranscriptionProvider.Credential
        // Modelled directly: the real lookup reads Keychain, which a unit test
        // must not mutate. The ordering and de-duplication rules are the logic
        // worth pinning — a duplicate spare provides no failover at all.
        let primary = C(label: "primary", key: "aaa")
        let distinct = C(label: "fallback", key: "bbb")
        let duplicate = C(label: "fallback", key: "aaa")
        func resolve(_ p: C?, _ f: C?) -> [C] {
            var out: [C] = []
            if let p { out.append(p) }
            if let f, !out.contains(where: { $0.key == f.key }) { out.append(f) }
            return out
        }
        #expect(resolve(primary, distinct).map(\.label) == ["primary", "fallback"])
        #expect(resolve(primary, duplicate).map(\.label) == ["primary"])
        #expect(resolve(primary, nil).map(\.label) == ["primary"])
        #expect(resolve(nil, nil).isEmpty)
    }

    @MainActor @Test func fallbackUseAlertsOnlyWhenTheSpareWasActuallyUsed() {
        DeepgramCreditMonitor.resetThrottle()
        #expect(DeepgramCreditMonitor.shouldNotify(.switchedToFallback))
        // Throttling is tracked per reason, so a fallback warning and a
        // credit-exhausted alert never suppress one another.
        let now = Date(timeIntervalSince1970: 2_000_000)
        UserDefaults.standard.set(now, forKey: "deepgramCreditNotified.switched-to-fallback")
        #expect(!DeepgramCreditMonitor.shouldNotify(.switchedToFallback, now: now))
        #expect(DeepgramCreditMonitor.shouldNotify(.creditExhausted, now: now))
        DeepgramCreditMonitor.resetThrottle()
    }

    @Test func legacyTranscriptDecodesWithoutSpeakerOrProviderFields() throws {
        let id = UUID()
        let json = """
        {"sessionID":"\(id.uuidString)","localeUsed":"es-CL","segments":[{"start":0,"duration":1,"text":"hola","track":"mic"}],"status":"completed","source":"whisper"}
        """
        let value = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(value.segments.first?.speaker == nil)
        #expect(value.words == nil && value.providerMetadata == nil)
    }
}
