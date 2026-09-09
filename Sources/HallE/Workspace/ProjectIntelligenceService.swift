import Foundation
import GRDB

actor ProjectIntelligenceService {
    static let shared = ProjectIntelligenceService()

    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private let minimumAutomaticInterval: TimeInterval = 15 * 60

    func scheduleRefresh(projectId: String) {
        scheduleRefresh(projectId: projectId, after: 3)
    }

    private func scheduleRefresh(projectId: String, after delay: TimeInterval) {
        refreshTasks[projectId]?.cancel()
        refreshTasks[projectId] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let project = AliasStore.shared.projects.first(where: { $0.id == projectId }) else { return }
            try? await refresh(project: project, force: false)
        }
    }

    func scheduleRefreshAll() {
        for project in AliasStore.shared.projects where !project.isArchived { scheduleRefresh(projectId: project.id) }
    }

    @discardableResult
    func refresh(project: Project, force: Bool) async throws -> ProjectSnapshotRecord {
        let context = try await makeContext(project: project)
        let existing = try await AppDatabase.shared.dbQueue.read { db in
            try ProjectSnapshotRecord.fetchOne(db, key: project.id)
        }
        if !force, let existing {
            if existing.sourceRevision == context.sourceRevision { return existing }
            let elapsed = Date().timeIntervalSince(existing.generatedAt)
            if elapsed < minimumAutomaticInterval {
                scheduleRefresh(projectId: project.id, after: minimumAutomaticInterval - elapsed)
                return existing
            }
        }

        let provider = LLMProviderFactory.make()
        let payload: ProjectSnapshotPayload
        if provider is DisabledLLMProvider {
            payload = try await fallbackSnapshot(project: project, context: context)
        } else {
            payload = try await provider.generateProjectSnapshot(context: context)
        }
        let record = ProjectSnapshotRecord(projectId: project.id, payload: payload,
                                           sourceRevision: context.sourceRevision,
                                           providerName: provider.providerName)
        try await AppDatabase.shared.dbQueue.write { db in try record.save(db) }
        await writeToObsidian(record, projectName: project.name)
        await VaultIndex.shared.reindex()
        await MainActor.run {
            NotificationCenter.default.post(name: .halleProjectSnapshotChanged,
                                            object: nil, userInfo: ["projectId": project.id])
        }
        return record
    }

    func answer(_ question: String, project: Project) async throws -> ProjectAssistantAnswer {
        let context = try await makeContext(project: project)
        let provider = LLMProviderFactory.make()
        guard !(provider is DisabledLLMProvider) else { throw LLMError.featureDisabled }
        try await saveMessage(projectId: project.id, role: "user", body: question, citations: [])
        let answer = try await provider.answerProjectQuestion(question, context: context)
        try await saveMessage(projectId: project.id, role: "assistant", body: answer.answer,
                              citations: answer.citations)
        return answer
    }

    func makeContext(project: Project) async throws -> ProjectAssistantContext {
        let values = try await AppDatabase.shared.dbQueue.read { db in
            let vault = try VaultDocument.filter(project.referenceNames.contains(VaultDocument.Columns.project)).fetchAll(db)
            let actions = try IndexedActionItem.filter(project.referenceNames.contains(IndexedActionItem.Columns.project)).fetchAll(db)
            let meetings = try UnifiedEvent.fetchAll(db)
            let sources = try ProjectSourceRecord.filter(ProjectSourceRecord.Columns.projectId == project.id).fetchAll(db)
            let documents = try ProjectSourceDocument.filter(ProjectSourceDocument.Columns.projectId == project.id).fetchAll(db)
            return (vault, actions, meetings, sources, documents)
        }
        let config = LLMProviderConfig.load()
        let localProvider = config.kind == .ollama || config.kind == .lmStudio
        let allowsSensitiveContent = localProvider || config.allowCloudTranscriptProcessing
        return ProjectKnowledgeContextBuilder().build(
            project: project, vaultDocuments: values.0, actions: values.1,
            meetings: values.2, sources: values.3, sourceDocuments: values.4,
            includeRawTranscripts: allowsSensitiveContent,
            includeExternalContent: allowsSensitiveContent)
    }

    private func fallbackSnapshot(project: Project, context: ProjectAssistantContext) async throws -> ProjectSnapshotPayload {
        let counts = try await AppDatabase.shared.dbQueue.read { db -> (Int, Int, Int) in
            let meetings = try UnifiedEvent.filter(project.referenceNames.contains(UnifiedEvent.Columns.projectId)).fetchCount(db)
            let actions = try IndexedActionItem.filter(project.referenceNames.contains(IndexedActionItem.Columns.project)
                && IndexedActionItem.Columns.isCompleted == false).fetchCount(db)
            let sources = try ProjectSourceRecord.filter(ProjectSourceRecord.Columns.projectId == project.id).fetchCount(db)
            return (meetings, actions, sources)
        }
        return ProjectSnapshotPayload(
            summary: "\(project.name) currently has \(counts.0) indexed meetings, \(counts.1) open commitments, and \(counts.2) linked sources.",
            status: "AI is not configured; this brief contains indexed counts only.",
            health: "unknown", goals: [], decisions: [], blockers: [], risks: [],
            nextSteps: counts.1 > 0 ? ["Review the open commitments."] : [],
            openQuestions: [], agenda: ["Review recent activity", "Confirm priorities and next steps"],
            citations: Array(context.citations.prefix(6)), confidence: nil)
    }

    private func saveMessage(projectId: String, role: String, body: String,
                             citations: [ProjectCitation]) async throws {
        let data = try JSONEncoder().encode(citations)
        let record = ProjectAssistantMessageRecord(id: UUID().uuidString, projectId: projectId,
                                                   role: role, body: body,
                                                   citationsJSON: String(decoding: data, as: UTF8.self),
                                                   createdAt: Date())
        try await AppDatabase.shared.dbQueue.write { db in try record.insert(db) }
    }

    private func writeToObsidian(_ snapshot: ProjectSnapshotRecord, projectName: String) async {
        let markdown = Self.markdown(snapshot)
        await MainActor.run {
            guard let service = MeetingNoteService.make() else { return }
            do { try service.updateProjectAssistantSnapshot(projectName: projectName, markdown: markdown) }
            catch { Log.obsidian.error("project snapshot write failed: \(error, privacy: .public)") }
        }
    }

    private static func markdown(_ value: ProjectSnapshotRecord) -> String {
        func section(_ title: String, _ values: [String]) -> [String] {
            ["### \(title)"] + (values.isEmpty ? ["- None identified"] : values.map { "- \($0)" }) + [""]
        }
        var lines = [
            "> Automatically generated by Hall-e on \(value.generatedAt.formatted(date: .abbreviated, time: .shortened)).",
            "> Provider: \(value.providerName). Verify inferred guidance against the cited sources.",
            "", "### Status", value.status, "", value.summary, "",
        ]
        lines += section("Goals", value.goals)
        lines += section("Decisions", value.decisions)
        lines += section("Blockers", value.blockers)
        lines += section("Risks", value.risks)
        lines += section("Next steps", value.nextSteps)
        lines += section("Suggested agenda", value.agenda)
        lines += ["### Sources"] + (value.citations.isEmpty ? ["- No citations"] : value.citations.map {
            "- [\($0.id)] \($0.sourceLabel) — \($0.title)"
        })
        return lines.joined(separator: "\n")
    }
}

extension Notification.Name {
    static let halleProjectSnapshotChanged = Notification.Name("cl.gabriel.hall-e.projectSnapshotChanged")
}
