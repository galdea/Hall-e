import SwiftUI

struct MeetingProjectChooser: View {
    let event: UnifiedEvent
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: String?
    @State private var createNew = false
    @State private var rememberFuture = false
    @State private var recurring = false
    @State private var saving = false
    @State private var error: String?

    init(event: UnifiedEvent, onSave: @escaping () -> Void) {
        self.event = event
        self.onSave = onSave
        _selectedID = State(initialValue: AliasStore.shared.projectID(for: event.projectId) ?? "")
    }

    private var matches: [Project] {
        AliasStore.shared.projects.filter {
            !$0.isArchived && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Assign project").font(.title2.bold())
            Text(event.title).foregroundStyle(.secondary)
            TextField(createNew ? "New project name" : "Search projects", text: $query)
            Toggle("New project", isOn: $createNew)
            if !createNew {
                List(selection: $selectedID) {
                    Text("Unclassified").tag("")
                    ForEach(matches) { Text($0.name).tag($0.id) }
                }.frame(height: 200)
            }
            if recurring {
                Toggle("Also assign future meetings in this recurring series", isOn: $rememberFuture)
                Text("Existing choices for individual meetings take priority.").font(.caption).foregroundStyle(.secondary)
            }
            Text(rememberFuture ? "Applies to this meeting and future occurrences." : "Applies only to this meeting.").font(.caption)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(createNew ? "Create and assign" : "Assign") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(createNew && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 480).disabled(saving)
        .interactiveDismissDisabled(saving)
        .task {
            do { recurring = try await ProjectAssignmentStore.shared.isRecurring(event) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task { @MainActor in
            do {
                let id: String?
                if createNew {
                    let project = try AliasStore.shared.createProject(named: query)
                    id = project.id
                    selectedID = project.id
                    createNew = false
                    query = ""
                    onSave()
                } else { id = selectedID.flatMap { $0.isEmpty ? nil : $0 } }
                try await ProjectAssignmentStore.shared.assign(projectID: id, to: event, rememberFuture: rememberFuture)
                onSave()
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
