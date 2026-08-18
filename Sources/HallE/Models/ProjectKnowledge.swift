import Foundation
import GRDB

enum ProjectSourceKind: String, Codable, CaseIterable {
    case codex
    case chatGPT
    case whatsApp
    case obsidian

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .chatGPT: "ChatGPT"
        case .whatsApp: "WhatsApp"
        case .obsidian: "Obsidian"
        }
    }

    var symbol: String {
        switch self {
        case .codex: "terminal"
        case .chatGPT: "sparkles"
        case .whatsApp: "message.fill"
        case .obsidian: "doc.text"
        }
    }
}

struct ProjectSourceRecord: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var projectId: String
    var kind: ProjectSourceKind
    var displayName: String
    var location: String?
    var externalId: String?
    var includeInAI: Bool
    var lastImportedAt: Date?
    var lastError: String?
    var createdAt: Date

    static let databaseTableName = "project_source"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let projectId = Column(CodingKeys.projectId)
        static let kind = Column(CodingKeys.kind)
        static let lastImportedAt = Column(CodingKeys.lastImportedAt)
        static let createdAt = Column(CodingKeys.createdAt)
    }
}

struct ProjectSourceDocument: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var sourceId: String
    var projectId: String
    var kind: ProjectSourceKind
    var title: String
    var author: String?
    var occurredAt: Date?
    var body: String
    var contentHash: String
    var metadataJSON: String
    var importedAt: Date

    static let databaseTableName = "project_source_document"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let sourceId = Column(CodingKeys.sourceId)
        static let projectId = Column(CodingKeys.projectId)
        static let kind = Column(CodingKeys.kind)
        static let occurredAt = Column(CodingKeys.occurredAt)
        static let importedAt = Column(CodingKeys.importedAt)
    }
}

struct ProjectCitation: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sourceDocumentId: String
    var sourceLabel: String
    var title: String
    var excerpt: String
    var occurredAt: Date?
}

struct ProjectSnapshotPayload: Codable, Hashable {
    var summary: String
    var status: String
    var health: String
    var goals: [String]
    var decisions: [String]
    var blockers: [String]
    var risks: [String]
    var nextSteps: [String]
    var openQuestions: [String]
    var agenda: [String]
    var citations: [ProjectCitation]
    var confidence: Double?

    enum CodingKeys: String, CodingKey {
        case summary, status, health, goals, decisions, blockers, risks
        case nextSteps = "next_steps"
        case openQuestions = "open_questions"
        case agenda, citations, confidence
    }
}

struct ProjectSnapshotRecord: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var projectId: String
    var summary: String
    var status: String
    var health: String
    var goalsJSON: String
    var decisionsJSON: String
    var blockersJSON: String
    var risksJSON: String
    var nextStepsJSON: String
    var openQuestionsJSON: String
    var agendaJSON: String
    var citationsJSON: String
    var generatedAt: Date
    var sourceRevision: String
    var confidence: Double?
    var providerName: String

    var id: String { projectId }
    static let databaseTableName = "project_snapshot"

    enum Columns {
        static let projectId = Column(CodingKeys.projectId)
        static let generatedAt = Column(CodingKeys.generatedAt)
    }

    init(projectId: String, payload: ProjectSnapshotPayload, generatedAt: Date = Date(),
         sourceRevision: String, providerName: String) {
        self.projectId = projectId
        summary = payload.summary
        status = payload.status
        health = payload.health
        goalsJSON = Self.encode(payload.goals)
        decisionsJSON = Self.encode(payload.decisions)
        blockersJSON = Self.encode(payload.blockers)
        risksJSON = Self.encode(payload.risks)
        nextStepsJSON = Self.encode(payload.nextSteps)
        openQuestionsJSON = Self.encode(payload.openQuestions)
        agendaJSON = Self.encode(payload.agenda)
        citationsJSON = Self.encode(payload.citations)
        self.generatedAt = generatedAt
        self.sourceRevision = sourceRevision
        confidence = payload.confidence
        self.providerName = providerName
    }

    var goals: [String] { Self.decode([String].self, goalsJSON) ?? [] }
    var decisions: [String] { Self.decode([String].self, decisionsJSON) ?? [] }
    var blockers: [String] { Self.decode([String].self, blockersJSON) ?? [] }
    var risks: [String] { Self.decode([String].self, risksJSON) ?? [] }
    var nextSteps: [String] { Self.decode([String].self, nextStepsJSON) ?? [] }
    var openQuestions: [String] { Self.decode([String].self, openQuestionsJSON) ?? [] }
    var agenda: [String] { Self.decode([String].self, agendaJSON) ?? [] }
    var citations: [ProjectCitation] { Self.decode([ProjectCitation].self, citationsJSON) ?? [] }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(value.utf8))
    }
}

struct ProjectAssistantMessageRecord: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var projectId: String
    var role: String
    var body: String
    var citationsJSON: String
    var createdAt: Date

    static let databaseTableName = "project_assistant_message"

    enum Columns {
        static let projectId = Column(CodingKeys.projectId)
        static let createdAt = Column(CodingKeys.createdAt)
    }

    var citations: [ProjectCitation] {
        (try? JSONDecoder().decode([ProjectCitation].self, from: Data(citationsJSON.utf8))) ?? []
    }
}

struct ProjectAssistantAnswer: Codable, Hashable {
    var answer: String
    var citations: [ProjectCitation]
    var suggestedUpdates: [String]

    enum CodingKeys: String, CodingKey {
        case answer, citations
        case suggestedUpdates = "suggested_updates"
    }
}

struct ProjectAssistantContext: Sendable {
    var projectId: String
    var projectName: String
    var markdown: String
    var sourceRevision: String
    var citations: [ProjectCitation]
}
