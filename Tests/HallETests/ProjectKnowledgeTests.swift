import Testing
import Foundation
import GRDB
@testable import HallE

@Suite("Project knowledge")
struct ProjectKnowledgeTests {
    @Test func contextExcludesGeneratedBriefAndSensitiveSourcesWhenGated() {
        let project = Project(id: "p1", name: "Project One", aliases: [])
        let noteBody = """
        # Project One
        User-authored objective.
        <!-- hall-e:transcript:start -->
        private transcript
        <!-- hall-e:transcript:end -->
        <!-- hall-e:assistant-brief:start -->
        generated recursive brief
        <!-- hall-e:assistant-brief:end -->
        """
        let note = VaultDocument(path: "Projects/One.md", title: "One", type: "project",
                                 project: project.name, eventId: nil, contentHash: "h",
                                 modifiedAt: Date(), body: noteBody)
        let source = ProjectSourceRecord(id: "source", projectId: project.id, kind: .chatGPT,
                                         displayName: "ChatGPT", location: nil, externalId: nil,
                                         includeInAI: true, lastImportedAt: Date(), lastError: nil,
                                         createdAt: Date())
        let imported = ProjectSourceDocument(id: "doc", sourceId: source.id, projectId: project.id,
                                             kind: .chatGPT, title: "Private chat", author: nil,
                                             occurredAt: Date(), body: "sensitive imported chat",
                                             contentHash: "x", metadataJSON: "{}", importedAt: Date())
        let context = ProjectKnowledgeContextBuilder().build(
            project: project, vaultDocuments: [note], actions: [], meetings: [],
            sources: [source], sourceDocuments: [imported], includeRawTranscripts: false,
            includeExternalContent: false)
        #expect(context.markdown.contains("User-authored objective"))
        #expect(!context.markdown.contains("private transcript"))
        #expect(!context.markdown.contains("generated recursive brief"))
        #expect(!context.markdown.contains("sensitive imported chat"))
    }

    @Test func projectKnowledgeRecordsRoundTripAndCascade() throws {
        let database = try AppDatabase(inMemory: true)
        let source = ProjectSourceRecord(id: "source", projectId: "p1", kind: .codex,
                                         displayName: "Codex", location: "/tmp/project",
                                         externalId: nil, includeInAI: true,
                                         lastImportedAt: nil, lastError: nil, createdAt: Date())
        let document = ProjectSourceDocument(id: "document", sourceId: source.id, projectId: "p1",
                                             kind: .codex, title: "Session", author: "Codex",
                                             occurredAt: Date(), body: "Implemented feature",
                                             contentHash: "hash", metadataJSON: "{}", importedAt: Date())
        try database.dbQueue.write { db in try source.insert(db); try document.insert(db) }
        let fetched = try database.dbQueue.read { db in try ProjectSourceRecord.fetchOne(db, key: source.id) }
        #expect(fetched?.kind == .codex)
        try database.dbQueue.write { db in _ = try source.delete(db) }
        let remaining = try database.dbQueue.read { db in try ProjectSourceDocument.fetchCount(db) }
        #expect(remaining == 0)
    }

    @Test func snapshotPreservesStructuredFields() {
        let citation = ProjectCitation(id: "S1", sourceDocumentId: "doc", sourceLabel: "Codex",
                                        title: "Session", excerpt: "Done", occurredAt: Date())
        let payload = ProjectSnapshotPayload(summary: "Summary", status: "Active", health: "on-track",
                                             goals: ["Launch"], decisions: ["Ship"], blockers: [],
                                             risks: ["Timing"], nextSteps: ["Test"],
                                             openQuestions: ["When?"], agenda: ["Review"],
                                             citations: [citation], confidence: 0.9)
        let record = ProjectSnapshotRecord(projectId: "p1", payload: payload,
                                           sourceRevision: "rev", providerName: "Test")
        #expect(record.goals == ["Launch"])
        #expect(record.nextSteps == ["Test"])
        #expect(record.citations == [citation])
    }
}
