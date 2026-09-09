import Foundation

/// Persisted, user-editable project definitions and aliases.
final class AliasStore: @unchecked Sendable {
    static let shared = AliasStore()

    private(set) var projects: [Project]
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL = AppPaths.aliasesFile, seed: [Project] = AliasStore.seed) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        } else {
            projects = seed
            // Never overwrite an unreadable existing directory on launch.
            if !FileManager.default.fileExists(atPath: fileURL.path) { save() }
        }
    }

    func reload() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    func update(_ project: Project) {
        do {
            try updateThrowing(project)
        } catch {
            Log.intel.error("Saving project directory failed: \(error, privacy: .public)")
        }
    }

    /// Persists a project without changing its stable ID. Renames keep the old
    /// display name as a project-name alias so legacy name-based references can
    /// still resolve after the rename.
    func updateThrowing(_ project: Project) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectDirectoryError.emptyName }
        if let existing = Self.project(resolving: project.name, in: projects), existing.id != project.id {
            throw ProjectDirectoryError.duplicateName
        }

        var stored = project
        let previous = projects.first { $0.id == project.id }
        Self.ensureProjectNameAlias(&stored, name: project.name)
        if let previous {
            for alias in previous.aliases where alias.kind == .projectName {
                Self.ensureProjectNameAlias(&stored, name: alias.text)
            }
        }
        if let previous, previous.name != project.name {
            Self.ensureProjectNameAlias(&stored, name: previous.name)
        }

        var next = projects
        if let i = next.firstIndex(where: { $0.id == stored.id }) { next[i] = stored }
        else { next.append(stored) }

        let data = try JSONEncoder().encode(next)
        try data.write(to: fileURL, options: [.atomic])
        projects = next
    }

    /// Projects with people-derived aliases folded in, for classification only
    /// (the editor still reads raw `projects`). Each tagged person contributes
    /// their emails as strong `.email` aliases and their full name as a weak
    /// `.personName` alias to every project they're assigned to.
    func classificationProjects(people: [Person] = PeopleStore.shared.people) -> [Project] {
        var byId = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        for person in people where !person.isArchived {
            for pid in person.projectIds {
                guard byId[pid] != nil else { continue }
                for email in person.emails where !email.isEmpty {
                    byId[pid]!.aliases.append(ProjectAlias(email, .email, .strong))
                }
                let name = person.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    byId[pid]!.aliases.append(ProjectAlias(name, .personName, .weak))
                }
            }
        }
        return projects.map { p in
            var merged = byId[p.id]!
            merged.aliases = Array(Set(merged.aliases))
            return merged
        }
    }

    func project(named name: String) -> Project? {
        projects.first { $0.name == name }
    }

    /// Resolves both stable IDs and legacy display-name references. Historical
    /// project-name aliases are included so a rename does not sever old links.
    func project(resolving reference: String?) -> Project? {
        Self.project(resolving: reference, in: projects)
    }

    func projectID(for reference: String?) -> String? {
        project(resolving: reference)?.id
    }

    func projectName(for reference: String?) -> String? {
        project(resolving: reference)?.name
    }

    func references(_ reference: String?, project: Project) -> Bool {
        self.project(resolving: reference)?.id == project.id
    }

    static func project(resolving reference: String?, in projects: [Project]) -> Project? {
        guard let raw = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let exactID = projects.first(where: { $0.id == raw }) { return exactID }
        if let exactName = projects.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exactName
        }
        return projects.first { project in
            project.aliases.contains {
                $0.kind == .projectName && $0.text.caseInsensitiveCompare(raw) == .orderedSame
            }
        }
    }

    /// Creates a project with a unique stable ID, or returns the existing
    /// project when the entered name already resolves to one.
    func createProject(named rawName: String) throws -> Project {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProjectDirectoryError.emptyName }
        if let existing = project(resolving: name) { return existing }

        let base = Self.stableSlug(name).isEmpty ? "project" : Self.stableSlug(name)
        var id = base
        let existingIDs = Set(projects.map(\.id))
        while existingIDs.contains(id) {
            id = base + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        }
        let project = Project(id: id, name: name,
                              aliases: [ProjectAlias(name, .projectName, .strong)])
        try updateThrowing(project)
        return project
    }

    private static func ensureProjectNameAlias(_ project: inout Project, name: String) {
        guard !project.aliases.contains(where: {
            $0.kind == .projectName && $0.text.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        project.aliases.append(ProjectAlias(name, .projectName, .strong))
    }

    static func stableSlug(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A new workspace belongs to its user; examples are test fixtures only.
    static let seed: [Project] = []

}

enum ProjectDirectoryError: LocalizedError {
    case emptyName
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .emptyName: "Project name cannot be empty."
        case .duplicateName: "A project already uses this name. Choose it from the project list or use another name."
        }
    }
}
