import SwiftUI

struct ProjectRulesSettingsView: View {
    @State private var projects = AliasStore.shared.projects
    @State private var selection: String?
    @State private var newAlias = ""
    @State private var newKind: AliasKind = .keyword
    @State private var newStrength: AliasStrength = .normal
    @State private var reclassifying = false
    @State private var showNewProject = false
    @State private var newProjectName = ""

    private var selected: Project? { projects.first { $0.id == selection } }

    /// folded keyword text → project names that use it (text signals only).
    private var keywordOwners: [String: [String]] {
        var map: [String: Set<String>] = [:]
        for p in projects {
            for a in p.aliases where a.kind.isTextSignal {
                map[TextNormalizer.fold(a.text), default: []].insert(p.name)
            }
        }
        return map.mapValues { $0.sorted() }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(projects, selection: $selection) { Text($0.name).tag($0.id) }
                Divider()
                HStack {
                    Button { newProjectName = ""; showNewProject = true } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }.padding(6)
            }
            .frame(minWidth: 150)
            if let project = selected {
                detail(project)
            } else {
                Text("Select a project").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Project Rules")
        .onAppear { if selection == nil { selection = projects.first?.id } }
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Project name (e.g. IMBA)", text: $newProjectName)
            Button("Create") { createProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a project you can then tag people and keywords to.")
        }
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let slug = TextNormalizer.fold(name).replacingOccurrences(of: " ", with: "-")
        guard !projects.contains(where: { $0.id == slug || $0.name == name }) else {
            selection = projects.first { $0.name == name }?.id; return
        }
        AliasStore.shared.update(Project(id: slug, name: name,
                                         aliases: [ProjectAlias(name, .projectName, .strong)]))
        projects = AliasStore.shared.projects
        selection = slug
    }

    private func detail(_ project: Project) -> some View {
        let keywords = project.aliases.filter { $0.kind.isTextSignal || $0.kind == .personName }
        let contacts = project.aliases.filter { $0.kind == .email || $0.kind == .domain }
        return Form {
            Section {
                Text("Signals used to classify meetings into \(project.name). Keywords shared with other projects are automatically down-weighted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Keywords") {
                if keywords.isEmpty { Text("None").foregroundStyle(.secondary).font(.caption) }
                ForEach(keywords, id: \.self) { aliasRow(project, $0) }
            }

            Section("Emails & domains") {
                if contacts.isEmpty {
                    Text("None — add an attendee email (e.g. ana@example.com) or a domain (example.com) to pin those meetings here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(contacts, id: \.self) { aliasRow(project, $0) }
            }

            Section("Add rule") {
                TextField("keyword, email, or domain…", text: $newAlias)
                    .onChange(of: newAlias) { _, t in newKind = Self.detectKind(t) }
                    .onSubmit { addAlias(project) }
                Picker("Type", selection: $newKind) {
                    ForEach([AliasKind.keyword, .email, .domain, .personName], id: \.self) {
                        Text($0.displayLabel).tag($0)
                    }
                }
                Picker("Strength", selection: $newStrength) {
                    Text("Normal").tag(AliasStrength.normal)
                    Text("Strong").tag(AliasStrength.strong)
                    Text("Weak").tag(AliasStrength.weak)
                }
                Button("Add") { addAlias(project) }
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section {
                Button {
                    Task { reclassifying = true; await SyncCoordinator.shared.syncAll(); reclassifying = false }
                } label: {
                    if reclassifying { HStack { ProgressView().controlSize(.small); Text("Re-classifying…") } }
                    else { Label("Re-run classification now", systemImage: "arrow.triangle.2.circlepath") }
                }
                .disabled(reclassifying)
                Text("Changes apply on the next sync; use this to reclassify your agenda immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }

    private func aliasRow(_ project: Project, _ alias: ProjectAlias) -> some View {
        let others = alias.kind.isTextSignal
            ? (keywordOwners[TextNormalizer.fold(alias.text)] ?? []).filter { $0 != project.name }
            : []
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(alias.text)
                if !others.isEmpty {
                    Label("also in: \(others.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(alias.strength.rawValue)
                .font(.caption2)
                .foregroundStyle(alias.strength == .weak ? .orange : .secondary)
            Button { remove(project, alias) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    static func detectKind(_ text: String) -> AliasKind {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("@") { return .email }
        if t.contains("."), !t.contains(" ") { return .domain }
        return .keyword
    }

    private func addAlias(_ project: Project) {
        let text = newAlias.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, var p = projects.first(where: { $0.id == project.id }) else { return }
        p.aliases.append(ProjectAlias(text, newKind, newStrength))
        persist(p)
        newAlias = ""; newKind = .keyword; newStrength = .normal
    }

    private func remove(_ project: Project, _ alias: ProjectAlias) {
        guard var p = projects.first(where: { $0.id == project.id }) else { return }
        p.aliases.removeAll { $0 == alias }
        persist(p)
    }

    private func persist(_ project: Project) {
        AliasStore.shared.update(project)
        projects = AliasStore.shared.projects
    }
}
