import Foundation
import Testing
@testable import HallE

struct MeetingBriefingPipelineTests {
    private func transcript() -> Transcript {
        Transcript(sessionID: UUID(), localeUsed: "multi",
                   segments: [
                    .init(start: 0, duration: 3, text: "Gabriel entregará el informe el 12 de agosto.", track: "mixed", speaker: 0),
                    .init(start: 4, duration: 2, text: "El objetivo es cerrar la migración.", track: "mixed", speaker: 1),
                   ], status: .completed, source: "deepgram:nova-3")
    }

    private func briefing(for transcript: Transcript) -> MeetingBriefing {
        let task = BriefingItem(id: "task-1", title: "Entregar informe", detail: nil,
                                ownerKind: .explicitName, ownerName: "Gabriel", explicitDate: "12 de agosto",
                                priority: 1, confidence: 0.95,
                                evidence: [.init(utteranceIndex: 0, start: 0, end: 3,
                                                 excerpt: "Gabriel entregará el informe el 12 de agosto")])
        let objective = BriefingItem(id: "objective-1", title: "Cerrar la migración", detail: nil,
                                     ownerKind: nil, ownerName: nil, explicitDate: nil, priority: 1,
                                     confidence: 0.9,
                                     evidence: [.init(utteranceIndex: 1, start: 4, end: 6,
                                                      excerpt: "El objetivo es cerrar la migración")])
        return .init(schemaVersion: MeetingBriefing.schema, headline: "Cierre de migración",
                     objectives: [objective], tasks: [task], decisions: [], risks: [], openQuestions: [],
                     milestones: [], confidence: 0.9, transcriptHash: transcript.contentHash,
                     promptVersion: OpenClawReportConfiguration.promptVersion,
                     model: "github-copilot/gemini-3.1-pro", generatedAt: "2026-08-09T15:00:00Z")
    }

    @Test func validatorAcceptsEvidenceBackedOwnerAndDate() throws {
        let transcript = transcript()
        try MeetingBriefingValidator.validate(briefing(for: transcript), transcript: transcript)
    }

    @Test func validatorRejectsInventedOwner() {
        let transcript = transcript(); var briefing = briefing(for: transcript)
        briefing.tasks[0].ownerName = "Alice"
        #expect(throws: BriefingValidationError.self) {
            try MeetingBriefingValidator.validate(briefing, transcript: transcript)
        }
    }

    @Test func markdownAndHTMLProtectCoreSectionsAndEscapeContent() {
        let transcript = transcript(); var value = briefing(for: transcript)
        value.headline = "Cierre <script>alert(1)</script>"
        let markdown = BriefingRenderer.markdown(value)
        let html = BriefingRenderer.html(value, profile: .corporateCloseKnit, designDirectory: nil)
        #expect(markdown.contains("## Objetivos"))
        #expect(markdown.contains("## Tareas individuales"))
        #expect(markdown.contains("## Decisiones"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("max-height:594mm"))
    }

    @Test func designProfileCannotHideRequiredSectionsOrUseRemoteLogo() {
        var profile = BriefingDesignProfile.corporateCloseKnit
        profile.accentColor = "javascript:red"
        profile.sectionOrder = ["risks"]
        profile.logoFileName = "https://example.com/logo.svg"
        let value = profile.validated(designDirectory: nil)
        #expect(value.accentColor == BriefingDesignProfile.corporateCloseKnit.accentColor)
        #expect(value.sectionOrder.prefix(3) == ["objectives", "tasks", "decisions"])
        #expect(value.logoFileName == nil)
    }

    @Test func openClawEnvelopeExtractionFindsCanonicalBriefing() throws {
        let transcript = transcript(); let value = briefing(for: transcript)
        let data = try JSONEncoder().encode(value)
        let escaped = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let envelope = #"{"payloads":[{"text":""# + escaped + #""}]}"#
        #expect(OpenClawReportClient.decodeBriefing(envelope)?.transcriptHash == transcript.contentHash)
    }

    @Test @MainActor func pdfRendererProducesALocalPDF() async throws {
        let transcript = transcript(); let value = briefing(for: transcript)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("halle-briefing-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await BriefingRenderer.renderPDF(value, profile: .corporateCloseKnit,
                                             designDirectory: nil, destination: destination)
        let data = try Data(contentsOf: destination)
        #expect(data.starts(with: Data("%PDF".utf8)))
    }

    @Test @MainActor func reconciliationCountsEveryTerminalBucket() {
        let base = HistoricalBackfillItem(id: UUID(), slug: "a", folderPath: "a", audioFileName: "a.m4a",
                                          audioSHA256: "a", audioBytes: 1, durationSeconds: 1, project: nil,
                                          priorTranscriptHash: nil, priorTranscriptSource: nil, estimatedCostUSD: 1,
                                          state: .completed, deepgramRequestID: "req", replacementTranscriptHash: "t",
                                          briefingHash: "b", lastError: nil)
        var failed = base; failed.id = UUID(); failed.state = .failed
        var ambiguous = base; ambiguous.id = UUID(); ambiguous.state = .ambiguous
        var skipped = base; skipped.id = UUID(); skipped.state = .skipped
        let manifest = HistoricalBackfillManifest(schemaVersion: HistoricalBackfillManifest.schema,
                                                  createdAt: Date(), expectedSessionCount: 4,
                                                  expectedDurationSeconds: 4, estimatedCostUSD: 4,
                                                  items: [base, failed, ambiguous, skipped],
                                                  acceptedABSessionIDs: [], sampleReportsApprovedAt: nil,
                                                  reconciliationAcceptedAt: nil, rollbackArtifact: nil)
        let value = HistoricalBackfillController.reconcile(manifest)
        #expect(value.completed == 1 && value.failed == 1 && value.ambiguous == 1 && value.skipped == 1)
    }

}
