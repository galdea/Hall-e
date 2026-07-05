import SwiftUI

struct PeopleSettingsView: View {
    @State private var people = PeopleStore.shared.people
    @State private var projects = AliasStore.shared.projects
    @State private var selection: String?
    @State private var reclassifying = false

    // edit buffers
    @State private var newEmail = ""
    @State private var newPhone = ""

    private var selected: Person? { people.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(people, selection: $selection) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name.isEmpty ? "(unnamed)" : p.name)
                        Text(projectNames(p)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(p.id)
                }
                Divider()
                HStack {
                    Button { addPerson() } label: { Label("Add Person", systemImage: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                }.padding(6)
            }
            .frame(minWidth: 180)

            if let person = selected {
                detail(person)
            } else {
                Text("Select or add a person").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("People")
        .onAppear { if selection == nil { selection = people.first?.id } }
    }

    private func detail(_ person: Person) -> some View {
        Form {
            Section("Name") {
                TextField("Full name", text: binding(person, \.name))
            }
            Section("Emails") {
                ForEach(person.emails, id: \.self) { email in
                    HStack {
                        Text(email)
                        Spacer()
                        Button { removeEmail(person, email) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("name@example.com", text: $newEmail).onSubmit { addEmail(person) }
                    Button("Add") { addEmail(person) }.disabled(newEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Phones") {
                ForEach(person.phones, id: \.self) { phone in
                    HStack {
                        Text(phone)
                        Spacer()
                        Button { removePhone(person, phone) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("+56912345678", text: $newPhone).onSubmit { addPhone(person) }
                    Button("Add") { addPhone(person) }.disabled(newPhone.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Projects") {
                ForEach(projects) { project in
                    Toggle(project.name, isOn: projectBinding(person, project.id))
                }
            }
            Section {
                Button {
                    Task { reclassifying = true; await SyncCoordinator.shared.syncAll(); reclassifying = false }
                } label: {
                    if reclassifying { HStack { ProgressView().controlSize(.small); Text("Re-classifying…") } }
                    else { Label("Re-run classification now", systemImage: "arrow.triangle.2.circlepath") }
                }.disabled(reclassifying)
                Button("Delete person", role: .destructive) {
                    PeopleStore.shared.remove(person); people = PeopleStore.shared.people; selection = people.first?.id
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mutations

    private func addPerson() {
        let p = Person(name: "New person")
        PeopleStore.shared.update(p); people = PeopleStore.shared.people; selection = p.id
    }
    private func addEmail(_ person: Person) {
        var p = person; let e = newEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard !e.isEmpty, !p.emails.contains(e) else { return }
        p.emails.append(e); persist(p); newEmail = ""
    }
    private func removeEmail(_ person: Person, _ email: String) {
        var p = person; p.emails.removeAll { $0 == email }; persist(p)
    }
    private func addPhone(_ person: Person) {
        var p = person; let ph = newPhone.trimmingCharacters(in: .whitespaces)
        guard !ph.isEmpty, !p.phones.contains(ph) else { return }
        p.phones.append(ph); persist(p); newPhone = ""
    }
    private func removePhone(_ person: Person, _ phone: String) {
        var p = person; p.phones.removeAll { $0 == phone }; persist(p)
    }
    private func persist(_ person: Person) {
        PeopleStore.shared.update(person); people = PeopleStore.shared.people
    }

    private func binding(_ person: Person, _ keyPath: WritableKeyPath<Person, String>) -> Binding<String> {
        Binding(
            get: { people.first { $0.id == person.id }?[keyPath: keyPath] ?? "" },
            set: { var p = person; p[keyPath: keyPath] = $0; persist(p) }
        )
    }
    private func projectBinding(_ person: Person, _ projectId: String) -> Binding<Bool> {
        Binding(
            get: { people.first { $0.id == person.id }?.projectIds.contains(projectId) ?? false },
            set: { on in
                var p = person
                if on { if !p.projectIds.contains(projectId) { p.projectIds.append(projectId) } }
                else { p.projectIds.removeAll { $0 == projectId } }
                persist(p)
            }
        )
    }

    private func projectNames(_ p: Person) -> String {
        let names = p.projectIds.compactMap { id in projects.first { $0.id == id }?.name }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }
}
