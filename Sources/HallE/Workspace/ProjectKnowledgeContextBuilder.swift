import Foundation
import CryptoKit

struct ProjectKnowledgeContextBuilder {
    var maximumCharacters = 60_000
    var maximumExternalDocuments = 32
    var maximumVaultDocuments = 16
    var maximumMeetings = 12

    func build(project: Project, vaultDocuments: [VaultDocument], actions: [IndexedActionItem],
               meetings: [UnifiedEvent], sources: [ProjectSourceRecord],
               sourceDocuments: [ProjectSourceDocument], includeRawTranscripts: Bool,
               includeExternalContent: Bool = true) -> ProjectAssistantContext {
        let enabledSourceIDs = Set(sources.filter { $0.projectId == project.id && $0.includeInAI }.map(\.id))
        let projectVault = vaultDocuments.filter { project.matchesReference($0.project) }.prefix(maximumVaultDocuments)
        let projectExternal = sourceDocuments.filter {
            $0.projectId == project.id && enabledSourceIDs.contains($0.sourceId)
        }.sorted { ($0.occurredAt ?? $0.importedAt) > ($1.occurredAt ?? $1.importedAt) }
            .prefix(includeExternalContent ? maximumExternalDocuments : 0)
        let projectMeetings = meetings.filter {
            project.matchesReference($0.projectId)
        }.sorted { $0.startTs > $1.startTs }.prefix(maximumMeetings)
        let projectActions = actions.filter { project.matchesReference($0.project) && !$0.isCompleted }
        let sourceNames = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.displayName) })

        var citations: [ProjectCitation] = []
        var sections: [String] = [
            "# \(project.name) — Hall-e project context",
            "",
            "## Open commitments",
        ]
        sections += projectActions.isEmpty ? ["- None indexed"] : projectActions.prefix(20).map {
            var value = "- \($0.task)"
            if let owner = $0.owner { value += " — owner: \(owner)" }
            if let dueDate = $0.dueDate { value += " — due: \(dueDate)" }
            return value
        }

        sections += ["", "## Recent meetings"]
        for event in projectMeetings {
            let citation = ProjectCitation(id: "S\(citations.count + 1)",
                                              sourceDocumentId: "meeting:\(event.dedupKey)",
                                              sourceLabel: "Calendar",
                                              title: event.title,
                                              excerpt: Self.excerpt(event.descriptionText ?? event.title),
                                              occurredAt: event.startTs)
            citations.append(citation)
            var line = "### [\(citation.id)] \(event.title) — \(event.startTs.formatted(date: .abbreviated, time: .shortened))"
            if let description = event.descriptionText, !description.isEmpty { line += "\n\(String(description.prefix(2_000)))" }
            sections += ["", line]
        }

        sections += ["", "## Project notes"]
        for document in projectVault {
            let citation = ProjectCitation(id: "S\(citations.count + 1)", sourceDocumentId: "vault:\(document.path)",
                                              sourceLabel: "Local notes", title: document.title,
                                              excerpt: Self.excerpt(document.body), occurredAt: document.modifiedAt)
            citations.append(citation)
            let transcriptSafe = includeRawTranscripts ? document.body : Self.withoutTranscript(document.body)
            let body = Self.withoutAssistantBrief(transcriptSafe)
            sections += ["", "### [\(citation.id)] \(document.title)", String(body.prefix(6_000))]
        }

        sections += ["", "## Imported project conversations"]
        for document in projectExternal {
            let citation = ProjectCitation(id: "S\(citations.count + 1)", sourceDocumentId: document.id,
                                              sourceLabel: sourceNames[document.sourceId] ?? document.kind.displayName,
                                              title: document.title, excerpt: Self.excerpt(document.body),
                                              occurredAt: document.occurredAt)
            citations.append(citation)
            var heading = "### [\(citation.id)] \(document.title) — \(citation.sourceLabel)"
            if let author = document.author { heading += " — \(author)" }
            sections += ["", heading, String(document.body.prefix(6_000))]
        }

        var markdown = sections.joined(separator: "\n")
        if markdown.count > maximumCharacters { markdown = String(markdown.prefix(maximumCharacters)) }
        let revisionInput = citations.map(\.sourceDocumentId).joined(separator: "\n") + markdown
        let revision = SHA256.hash(data: Data(revisionInput.utf8)).map { String(format: "%02x", $0) }.joined()
        return ProjectAssistantContext(projectId: project.id, projectName: project.name,
                                       markdown: markdown, sourceRevision: revision,
                                       citations: citations)
    }

    private static func excerpt(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    }

    private static func withoutTranscript(_ markdown: String) -> String {
        let start = "<!-- hall-e:transcript:start -->"
        let end = "<!-- hall-e:transcript:end -->"
        guard let lower = markdown.range(of: start),
              let upper = markdown.range(of: end, range: lower.upperBound..<markdown.endIndex) else { return markdown }
        var copy = markdown
        copy.replaceSubrange(lower.upperBound..<upper.lowerBound, with: "\n_(raw transcript excluded)_\n")
        return copy
    }

    private static func withoutAssistantBrief(_ markdown: String) -> String {
        let start = "<!-- hall-e:assistant-brief:start -->"
        let end = "<!-- hall-e:assistant-brief:end -->"
        guard let lower = markdown.range(of: start),
              let upper = markdown.range(of: end, range: lower.upperBound..<markdown.endIndex) else { return markdown }
        var copy = markdown
        copy.replaceSubrange(lower.upperBound..<upper.lowerBound, with: "\n_(generated project brief excluded)_\n")
        return copy
    }
}
