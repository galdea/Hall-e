import SwiftUI

struct ProjectEditorView: View {
    let project: Project?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var aliases: String
    @State private var saveError: String?
    @State private var saving = false
    @State private var createdID: String?

    init(project: Project?, onSave: @escaping () -> Void) {
        self.project = project; self.onSave = onSave
        _name = State(initialValue: project?.name ?? "")
        _aliases = State(initialValue: project?.aliases.map(\.text).joined(separator: "\n") ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(project == nil ? "New Project" : "Edit Project").font(.title2.weight(.semibold))
            TextField("Project name", text: $name)
            Text("Classification keywords, one per line").font(.headline)
            TextEditor(text: $aliases).font(.body.monospaced()).frame(minHeight: 180).overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("The stable project ID will not change when you rename this label.").font(.caption).foregroundStyle(.secondary)
            if let saveError { Text(saveError).foregroundStyle(.red) }
            HStack { Spacer(); Button(L10n.text("common.cancel")) { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 480).disabled(saving).interactiveDismissDisabled(saving)
    }
    private func save() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = project?.id ?? createdID ?? stableSlug(clean) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        createdID = id
        let entries = aliases.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { ProjectAlias($0, .keyword, .normal) }
        saving = true
        saveError = nil
        Task { @MainActor in
            do {
                // Preserve alias kinds/strengths for unchanged editor lines.
                let preserved = entries.flatMap { entry -> [ProjectAlias] in
                    let original = project?.aliases.filter { $0.text == entry.text } ?? []
                    return original.isEmpty ? [entry] : original
                }
                try AliasStore.shared.updateThrowing(Project(id: id, name: clean, aliases: preserved, isArchived: project?.isArchived ?? false))
                try await ProjectAssignmentStore.shared.refreshDisplayName(projectID: id, previousName: project?.name)
                onSave(); dismiss()
            } catch { saveError = error.localizedDescription }
            saving = false
        }
    }
    private func stableSlug(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

struct PersonEditorView: View {
    let person: Person?
    let projects: [Project]
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var emails: String
    @State private var phones: String
    @State private var projectIDs: Set<String>
    @State private var notes: String
    init(person: Person?, projects: [Project], onSave: @escaping () -> Void) {
        self.person = person; self.projects = projects; self.onSave = onSave
        _name = State(initialValue: person?.name ?? ""); _emails = State(initialValue: person?.emails.joined(separator: ", ") ?? "")
        _phones = State(initialValue: person?.phones.joined(separator: ", ") ?? ""); _projectIDs = State(initialValue: Set(person?.projectIds ?? [])); _notes = State(initialValue: person?.notes ?? "")
    }
    var body: some View {
        Form {
            Section { TextField("Name", text: $name); TextField("Emails, separated by commas", text: $emails); TextField("Phones, separated by commas", text: $phones) }
            Section("Projects and classification signals") { ForEach(projects) { project in Toggle(project.name, isOn: Binding(get: { projectIDs.contains(project.id) }, set: { if $0 { projectIDs.insert(project.id) } else { projectIDs.remove(project.id) } })) } }
            Section("Notes") { TextEditor(text: $notes).frame(minHeight: 90) }
            HStack { Spacer(); Button(L10n.text("common.cancel")) { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.formStyle(.grouped).padding(10).frame(width: 520, height: 500)
    }
    private func save() {
        func split(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        PeopleStore.shared.update(Person(id: person?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), emails: split(emails), phones: split(phones), projectIds: Array(projectIDs), notes: notes.isEmpty ? nil : notes, isArchived: person?.isArchived ?? false))
        onSave(); dismiss()
    }
}
