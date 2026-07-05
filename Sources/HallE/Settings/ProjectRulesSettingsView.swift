import SwiftUI

struct ProjectRulesSettingsView: View {
    @State private var projects = AliasStore.shared.projects
    @State private var selection: String?
    @State private var newAlias = ""

    private var selected: Project? { projects.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            List(projects, selection: $selection) { project in
                Text(project.name).tag(project.id)
            }
            .frame(minWidth: 160)

            if let project = selected {
                detail(project)
            } else {
                Text("Select a project").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Project Rules")
        .onAppear { if selection == nil { selection = projects.first?.id } }
    }

    private func detail(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(project.name).font(.title3).bold()
            Text("Keywords and aliases used to classify meetings into this project.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(project.aliases, id: \.self) { alias in
                    HStack {
                        Text(alias.text)
                        Spacer()
                        Text(alias.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        Text(alias.strength.rawValue)
                            .font(.caption2)
                            .foregroundStyle(alias.strength == .weak ? .orange : .green)
                    }
                }
                .onDelete { idx in removeAlias(project, at: idx) }
            }

            HStack {
                TextField("Add keyword…", text: $newAlias)
                    .onSubmit { addAlias(project) }
                Button("Add") { addAlias(project) }
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func addAlias(_ project: Project) {
        let text = newAlias.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, var p = projects.first(where: { $0.id == project.id }) else { return }
        p.aliases.append(ProjectAlias(text, .keyword, .normal))
        persist(p)
        newAlias = ""
    }

    private func removeAlias(_ project: Project, at offsets: IndexSet) {
        guard var p = projects.first(where: { $0.id == project.id }) else { return }
        p.aliases.remove(atOffsets: offsets)
        persist(p)
    }

    private func persist(_ project: Project) {
        AliasStore.shared.update(project)
        projects = AliasStore.shared.projects
    }
}
