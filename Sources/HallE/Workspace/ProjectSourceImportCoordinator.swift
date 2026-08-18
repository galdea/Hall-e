import Foundation
import CryptoKit
import GRDB

actor ProjectSourceImportCoordinator {
    static let shared = ProjectSourceImportCoordinator()

    func linkCodex(projectId: String, projectName: String, folder: URL) async throws -> ProjectSourceRecord {
        let standardized = folder.standardizedFileURL.path
        let sourceId = Self.digest("codex|\(projectId)|\(standardized)")
        let existing = try await AppDatabase.shared.dbQueue.read { db in
            try ProjectSourceRecord.fetchOne(db, key: sourceId)
        }
        var source = ProjectSourceRecord(id: sourceId, projectId: projectId, kind: .codex,
                                         displayName: "Codex · \(folder.lastPathComponent)",
                                         location: standardized, externalId: standardized,
                                         includeInAI: existing?.includeInAI ?? true,
                                         lastImportedAt: existing?.lastImportedAt,
                                         lastError: nil, createdAt: existing?.createdAt ?? Date())
        let initialSource = source
        try await AppDatabase.shared.dbQueue.write { db in try initialSource.save(db) }
        do {
            let documents = try CodexSessionImporter().load(from: folder)
            try await persist(documents, source: source)
            source.lastImportedAt = Date(); source.lastError = nil
            let completedSource = source
            try await AppDatabase.shared.dbQueue.write { db in try completedSource.save(db) }
            postChange(projectId)
            return source
        } catch {
            source.lastError = error.localizedDescription
            let failedSource = source
            try? await AppDatabase.shared.dbQueue.write { db in try failedSource.save(db) }
            throw error
        }
    }

    func importFile(projectId: String, kind: ProjectSourceKind, file: URL,
                    selectedDocuments: [NormalizedProjectDocument]? = nil) async throws -> ProjectSourceRecord {
        let standardized = file.standardizedFileURL.path
        let importIdentity = kind == .chatGPT ? "account-export" : file.deletingPathExtension().lastPathComponent
        let sourceId = Self.digest("\(kind.rawValue)|\(projectId)|\(importIdentity)")
        let existing = try await AppDatabase.shared.dbQueue.read { db in
            try ProjectSourceRecord.fetchOne(db, key: sourceId)
        }
        var source = ProjectSourceRecord(id: sourceId, projectId: projectId, kind: kind,
                                         displayName: "\(kind.displayName) · \(file.lastPathComponent)",
                                         location: standardized, externalId: file.lastPathComponent,
                                         includeInAI: existing?.includeInAI ?? true,
                                         lastImportedAt: existing?.lastImportedAt,
                                         lastError: nil, createdAt: existing?.createdAt ?? Date())
        let initialSource = source
        try await AppDatabase.shared.dbQueue.write { db in try initialSource.save(db) }
        do {
            let importer: any ProjectSourceImporter = kind == .chatGPT
                ? ChatGPTExportImporter() : WhatsAppExportImporter()
            let documents = try selectedDocuments ?? importer.load(from: file)
            try await persist(documents, source: source)
            source.lastImportedAt = Date(); source.lastError = nil
            let completedSource = source
            try await AppDatabase.shared.dbQueue.write { db in try completedSource.save(db) }
            postChange(projectId)
            return source
        } catch {
            source.lastError = error.localizedDescription
            let failedSource = source
            try? await AppDatabase.shared.dbQueue.write { db in try failedSource.save(db) }
            throw error
        }
    }

    func refresh(_ source: ProjectSourceRecord) async throws {
        guard let location = source.location else { return }
        if source.kind == .codex {
            _ = try await linkCodex(projectId: source.projectId, projectName: source.displayName,
                                    folder: URL(fileURLWithPath: location))
        } else if source.kind == .chatGPT || source.kind == .whatsApp {
            _ = try await importFile(projectId: source.projectId, kind: source.kind,
                                     file: URL(fileURLWithPath: location))
        }
    }

    func remove(_ source: ProjectSourceRecord) async throws {
        try await AppDatabase.shared.dbQueue.write { db in _ = try source.delete(db) }
        postChange(source.projectId)
    }

    func refreshLinkedCodexSources() async {
        let sources = (try? await AppDatabase.shared.dbQueue.read { db in
            try ProjectSourceRecord.filter(ProjectSourceRecord.Columns.kind == ProjectSourceKind.codex.rawValue).fetchAll(db)
        }) ?? []
        for source in sources { try? await refresh(source) }
    }

    private func persist(_ documents: [NormalizedProjectDocument], source: ProjectSourceRecord) async throws {
        let importedAt = Date()
        try await AppDatabase.shared.dbQueue.write { db in
            for document in documents {
                let contentHash = Self.digest(document.body)
                let id = Self.digest("\(source.id)|\(document.externalId)")
                let metadataData = try JSONEncoder().encode(document.metadata)
                let row = ProjectSourceDocument(id: id, sourceId: source.id,
                                                projectId: source.projectId, kind: source.kind,
                                                title: document.title, author: document.author,
                                                occurredAt: document.occurredAt, body: document.body,
                                                contentHash: contentHash,
                                                metadataJSON: String(decoding: metadataData, as: UTF8.self),
                                                importedAt: importedAt)
                try row.save(db)
            }
        }
    }

    private func postChange(_ projectId: String) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .halleProjectKnowledgeChanged,
                                            object: nil, userInfo: ["projectId": projectId])
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Notification.Name {
    static let halleProjectKnowledgeChanged = Notification.Name("cl.gabriel.hall-e.projectKnowledgeChanged")
}
