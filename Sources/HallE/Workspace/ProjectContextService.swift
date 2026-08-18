import Foundation

struct ProjectContextExportOptions: Equatable {
    var includeActions = true
    var includeNotes = true
    var includeTranscripts = false
    var maximumDocuments = 30
}

struct ProjectContextPreview: Equatable {
    let projectID: String
    let documentCount: Int
    let actionCount: Int
    let characterCount: Int
    let includesTranscripts: Bool
    let sourcePaths: [String]
}

struct ProjectContextService {
    func preview(project: Project, documents: [VaultDocument], actions: [IndexedActionItem],
                 options: ProjectContextExportOptions = .init()) -> ProjectContextPreview {
        let docs = documents.filter { $0.project == project.name }.prefix(options.maximumDocuments)
        let openActions = actions.filter { $0.project == project.name && !$0.isCompleted }
        let output = markdown(project: project, documents: documents, actions: actions, options: options)
        return ProjectContextPreview(projectID: project.id,
                                     documentCount: options.includeNotes ? docs.count : 0,
                                     actionCount: options.includeActions ? openActions.count : 0,
                                     characterCount: output.count,
                                     includesTranscripts: options.includeTranscripts,
                                     sourcePaths: docs.map(\.path))
    }

    func markdown(project: Project, documents: [VaultDocument], actions: [IndexedActionItem],
                  includeTranscripts: Bool = false) -> String {
        var options = ProjectContextExportOptions()
        options.includeTranscripts = includeTranscripts
        return markdown(project: project, documents: documents, actions: actions, options: options)
    }

    func markdown(project: Project, documents: [VaultDocument], actions: [IndexedActionItem],
                  options: ProjectContextExportOptions) -> String {
        let projectDocs = documents.filter { $0.project == project.name }
        let projectActions = actions.filter { $0.project == project.name && !$0.isCompleted }
        var lines = [
            "# \(project.name) — Hall-e context",
            "",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "",
            "## Open actions",
        ]
        lines += !options.includeActions ? ["- Excluded by export settings"] : projectActions.isEmpty ? ["- None indexed"] : projectActions.map {
            var line = "- [ ] \($0.task)"
            if let owner = $0.owner { line += " (@\(owner))" }
            if let due = $0.dueDate { line += " — due \(due)" }
            line += "  _Source: \($0.notePath)_"
            return line
        }
        lines += ["", "## Project notes"]
        if !options.includeNotes { lines.append("- Excluded by export settings") }
        for document in options.includeNotes ? projectDocs.prefix(options.maximumDocuments) : projectDocs.prefix(0) {
            lines += ["", "### \(document.title)", "_Source: \(document.path)_"]
            let body = options.includeTranscripts ? document.body : withoutTranscript(document.body)
            lines.append(String(body.prefix(12_000)))
        }
        return lines.joined(separator: "\n")
    }

    func writePack(project: Project, documents: [VaultDocument], actions: [IndexedActionItem],
                   options: ProjectContextExportOptions) throws -> URL {
        let folder = AppPaths.appSupport.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent("\(FilenameSanitizer.sanitize(project.name, maxBytes: 64))-ChatGPT.md")
        try markdown(project: project, documents: documents, actions: actions, options: options)
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private func withoutTranscript(_ markdown: String) -> String {
        let start = "<!-- hall-e:transcript:start -->"
        let end = "<!-- hall-e:transcript:end -->"
        guard let a = markdown.range(of: start),
              let b = markdown.range(of: end, range: a.upperBound..<markdown.endIndex) else { return markdown }
        var copy = markdown
        copy.replaceSubrange(a.upperBound..<b.lowerBound, with: "\n_(raw transcript excluded)_\n")
        return copy
    }
}
