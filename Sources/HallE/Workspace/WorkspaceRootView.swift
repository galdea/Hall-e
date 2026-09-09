import SwiftUI
import AppKit
import GRDB

struct WorkspaceRootView: View {
    @State var model = WorkspaceViewModel()
    @State private var language = AppLanguageStore.shared
    @State private var recorder = RecordingService.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            routeContent
                .navigationTitle(model.route.title)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .safeAreaInset(edge: .top, spacing: 0) { RecordingPromptBanner() }
        .environment(\.locale, language.locale)
        .id(language.language)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if recorder.isRecording {
                    Button { recorder.stop() } label: {
                        Label(recorder.elapsed.formattedDuration, systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                    }.help("Stop recording")
                }
                SyncHealthButton()
                Button { model.route = .search } label: { Image(systemName: "magnifyingglass") }
                    .keyboardShortcut("f", modifiers: .command).help(L10n.text("workspace.search"))
                Button { SettingsWindowController.shared.show() } label: { Image(systemName: "gearshape") }
                    .help(L10n.text("common.settings"))
            }
        }
    }

    private var sidebar: some View {
        List(selection: $model.route) {
            Section(L10n.text("sidebar.focus")) {
                routeRow(.today); routeRow(.inbox)
            }
            Section(L10n.text("sidebar.organize")) {
                routeRow(.projects); routeRow(.meetings); routeRow(.actions)
            }
            Section("Directory") { routeRow(.people); routeRow(.search) }
        }
        .navigationTitle(L10n.text("app.name"))
        .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 250)
    }

    private func routeRow(_ route: WorkspaceRoute) -> some View {
        Label {
            HStack {
                Text(route.title)
                Spacer()
                let badge = model.badge(for: route)
                if badge > 0 { Text("\(badge)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: route.symbol) }
        .tag(route)
        .accessibilityLabel(route.title)
    }

    @ViewBuilder private var routeContent: some View {
        switch model.route {
        case .today: TodayWorkspaceView(model: model)
        case .inbox: InboxWorkspaceView(model: model)
        case .projects: ProjectsWorkspaceView(model: model)
        case .meetings: MeetingsWorkspaceView(model: model)
        case .actions: ActionsWorkspaceView(model: model)
        case .people: PeopleWorkspaceView(model: model)
        case .search: SearchWorkspaceView(model: model)
        }
    }

    @ViewBuilder private var detailContent: some View {
        switch model.selection {
        case .meeting(let key):
            if let event = model.appState.agenda.first(where: { $0.dedupKey == key }) ?? model.requestedMeeting.flatMap({ $0.dedupKey == key ? $0 : nil }) {
                MeetingInspectorView(event: event, model: model)
            } else { missingSelection }
        case .project(let id):
            if let project = model.projects.first(where: { $0.id == id }) { ProjectDetailView(project: project, model: model) }
            else { missingSelection }
        case .recording(let id):
            if let recording = model.recordings.first(where: { $0.id == id }) {
                RecordingDetailView(session: recording) { model.selection = nil }
            }
            else { missingSelection }
        case .action(let id):
            if let action = model.appState.actionItems.first(where: { $0.id == id }) { ActionDetailView(action: action) }
            else { missingSelection }
        case .person(let id):
            if let person = model.people.first(where: { $0.id == id }) { PersonDetailView(person: person, projects: model.projects) }
            else { missingSelection }
        case .document(let path):
            if let document = model.appState.vaultDocuments.first(where: { $0.path == path }) ?? model.searchResults.first(where: { $0.path == path }) {
                VaultDocumentDetailView(document: document)
            } else { missingSelection }
        case nil:
            HalleEmptyState(symbol: model.route.symbol, title: model.route.title,
                            detail: detailPrompt)
        }
    }

    private var missingSelection: some View {
        HalleEmptyState(symbol: "questionmark.folder", title: "Item unavailable",
                        detail: "It may have changed in Obsidian or during calendar sync.")
    }
    private var detailPrompt: String {
        switch model.route {
        case .today, .meetings: L10n.text("meeting.noSelection.detail")
        case .projects: "Select a project to see its brief and ChatGPT context."
        case .actions: "Select an action to see its source and metadata."
        case .people: "Select a person to see their projects and meeting signals."
        case .search: "Select a result to preview its indexed content."
        case .inbox: "Select an item to resolve it."
        }
    }
}

struct TodayWorkspaceView: View {
    let model: WorkspaceViewModel
    private var today: AgendaTimeline { TimelineBuilder.build(events: model.appState.agenda) }
    private var conflicts: Int {
        let events = today.hourGroups.flatMap(\.events).sorted { $0.startTs < $1.startTs }
        return zip(events, events.dropFirst()).filter { $0.endTs > $1.startTs }.count
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MetricPill(value: "\(today.hourGroups.flatMap(\.events).count)", label: "meetings")
                MetricPill(value: "\(model.appState.actionItems.filter { !$0.isCompleted }.count)", label: "open actions")
                MetricPill(value: "\(conflicts)", label: "conflicts")
                Spacer()
            }.padding([.horizontal, .top], 12)
            AgendaView(events: model.appState.agenda, hasAccounts: !model.appState.accounts.isEmpty) {
                model.selection = .meeting($0.dedupKey)
            }
        }
    }
}

struct InboxWorkspaceView: View {
    let model: WorkspaceViewModel
    var body: some View {
        if model.attentionItems.isEmpty {
            HalleEmptyState(symbol: "checkmark.circle", title: "You’re all caught up",
                            detail: "Meetings, recordings, and notes have no outstanding issues.")
        } else {
            List(model.attentionItems) { item in
                Button { recover(item) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol(item.kind)).foregroundStyle(tone(item.severity).color).frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).fontWeight(.medium).foregroundStyle(.primary)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }.padding(.vertical, 4)
                }.buttonStyle(.plain)
            }
        }
    }
    private func recover(_ item: AttentionItem) {
        if item.kind == .sync { Task { await SyncCoordinator.shared.syncAll() } }
        else if let selection = item.selection { model.selection = selection }
    }
    private func symbol(_ kind: AttentionItem.Kind) -> String {
        switch kind { case .classification: "folder.badge.questionmark"; case .transcription: "waveform.badge.exclamationmark"; case .sync: "arrow.triangle.2.circlepath"; case .vault: "externaldrive.badge.exclamationmark"; case .action: "checklist.unchecked" }
    }
    private func tone(_ severity: AttentionSeverity) -> HalleStatusTone {
        switch severity { case .info: .info; case .warning: .warning; case .error: .error }
    }
}

struct ProjectsWorkspaceView: View {
    let model: WorkspaceViewModel
    @State private var editingProject: Project?
    @State private var creatingProject = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Stable project identities organize meetings, actions, and exports.").font(.caption).foregroundStyle(.secondary); Spacer(); Button { creatingProject = true } label: { Label("New Project", systemImage: "plus") } }.padding(12)
            Divider()
            if model.projects.isEmpty { HalleEmptyState(symbol: "folder.badge.plus", title: "No projects", detail: "Create a project to organize meetings and notes.") }
            else {
                List(model.projects, selection: Binding(get: {
                    if case .project(let id) = model.selection { id } else { nil }
                }, set: { model.selection = $0.map(WorkspaceSelection.project) })) { project in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "folder.fill").font(.title3).foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(project.name).fontWeight(.semibold)
                                if let snapshot = model.snapshot(for: project) {
                                    HalleStatusBadge(text: snapshot.health.replacingOccurrences(of: "-", with: " ").capitalized,
                                                     tone: projectHealthTone(snapshot.health))
                                }
                            }
                            if let snapshot = model.snapshot(for: project) {
                                Text(snapshot.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            } else {
                                Text("No generated brief yet").font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Label("\(model.appState.actionItems.filter { project.matchesReference($0.project) && !$0.isCompleted }.count)", systemImage: "checklist")
                                Label("\(model.appState.agenda.filter { project.matchesReference($0.projectId) }.count)", systemImage: "calendar")
                                Label("\(model.sources(for: project).count)", systemImage: "externaldrive")
                                if let latest = model.activity(for: project).first {
                                    Text("· active \(latest.date.formatted(.relative(presentation: .named)))")
                                }
                            }.font(.caption2).foregroundStyle(.tertiary)
                        }
                    }.padding(.vertical, 4).tag(project.id)
                        .contextMenu { Button("Edit Project…") { editingProject = project } }
                }
            }
        }
        .sheet(isPresented: $creatingProject) { ProjectEditorView(project: nil) { model.refreshDirectory(); creatingProject = false } }
        .sheet(item: $editingProject) { project in ProjectEditorView(project: project) { model.refreshDirectory(); editingProject = nil } }
    }

    private func projectHealthTone(_ health: String) -> HalleStatusTone {
        switch health.lowercased() {
        case "on-track", "on track": .success
        case "at-risk", "at risk": .warning
        case "blocked": .error
        default: .neutral
        }
    }
}

struct MeetingsWorkspaceView: View {
    enum Filter: String, CaseIterable { case upcoming = "Upcoming", past = "Past", recordings = "Recordings" }
    let model: WorkspaceViewModel
    @State private var filter: Filter = .upcoming
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                TextField("Filter meetings", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
            }.padding(12)
            Divider()
            if filter == .recordings { recordingsList } else { meetingsList }
        }
        .onAppear { revealSelectedMeeting() }
        .onChange(of: model.selection) { _, _ in revealSelectedMeeting() }
    }

    private func revealSelectedMeeting() {
        guard case .meeting(let key) = model.selection,
              let event = model.appState.agenda.first(where: { $0.dedupKey == key })
                ?? model.requestedMeeting.flatMap({ $0.dedupKey == key ? $0 : nil }) else { return }
        filter = event.endTs < Date() ? .past : .upcoming
        query = ""
    }

    private var filteredEvents: [UnifiedEvent] {
        var events = model.appState.agenda
        if let requested = model.requestedMeeting, !events.contains(where: { $0.dedupKey == requested.dedupKey }) {
            events.append(requested)
        }
        return events.filter {
            (filter == .upcoming ? $0.endTs >= Date() : $0.endTs < Date()) &&
            (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.projectId?.localizedCaseInsensitiveContains(query) ?? false))
        }.sorted { filter == .upcoming ? $0.startTs < $1.startTs : $0.startTs > $1.startTs }
    }
    private var meetingsList: some View {
        List(filteredEvents) { event in EventRowView(event: event) { model.selection = .meeting($0.dedupKey) } }
    }
    private var recordingsList: some View {
        List(model.recordings.filter { query.isEmpty || $0.eventTitle.localizedCaseInsensitiveContains(query) }) { session in
            Button { model.selection = .recording(session.id) } label: {
                HStack {
                    VStack(alignment: .leading) { Text(session.eventTitle); Text(session.startedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); HalleStatusBadge(text: session.transcriptStatus.rawValue, tone: session.transcriptStatus == .failed ? .error : session.transcriptStatus == .completed ? .success : .warning)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

struct ActionsWorkspaceView: View {
    let model: WorkspaceViewModel
    var body: some View {
        List {
            ForEach(ActionBucket.allCases) { bucket in
                let items = model.actions(in: bucket)
                if !items.isEmpty {
                    Section(bucket.title) {
                        ForEach(items) { item in
                            Button { model.selection = .action(item.id) } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle").foregroundStyle(item.isCompleted ? .green : .secondary)
                                    VStack(alignment: .leading) {
                                        Text(item.task).strikethrough(item.isCompleted).foregroundStyle(.primary)
                                        HStack { if let project = item.project { Text(project) }; if let due = item.dueDate { Text("· \(due)") } }
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct PeopleWorkspaceView: View {
    let model: WorkspaceViewModel
    @State private var query = ""
    @State private var editingPerson: Person?
    @State private var creatingPerson = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { TextField("Search people", text: $query).textFieldStyle(.roundedBorder); Button { creatingPerson = true } label: { Label("New Person", systemImage: "plus") } }.padding(12)
            Divider()
            List(model.people.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.emails.contains(where: { $0.localizedCaseInsensitiveContains(query) }) }) { person in
                Button { model.selection = .person(person.id) } label: {
                    HStack {
                        Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading) { Text(person.name); Text(person.emails.first ?? "No email signals").font(.caption).foregroundStyle(.secondary) }
                    }
                }.buttonStyle(.plain).contextMenu { Button("Edit Person…") { editingPerson = person } }
            }
        }
        .sheet(isPresented: $creatingPerson) { PersonEditorView(person: nil, projects: model.projects) { model.refreshDirectory(); creatingPerson = false } }
        .sheet(item: $editingPerson) { person in PersonEditorView(person: person, projects: model.projects) { model.refreshDirectory(); editingPerson = nil } }
    }
}

struct SearchWorkspaceView: View {
    let model: WorkspaceViewModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles and note content", text: Binding(get: { model.searchQuery }, set: { model.searchQuery = $0 }))
                    .textFieldStyle(.plain)
                if model.isSearching { ProgressView().controlSize(.small) }
                Text("\(model.appState.vaultDocuments.count) indexed").font(.caption).foregroundStyle(.secondary)
                Button { Task { await VaultIndex.shared.reindex() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Rebuild vault index")
            }.padding(12)
            Divider()
            if model.searchQuery.isEmpty {
                HalleEmptyState(symbol: "magnifyingglass", title: "Search your vault", detail: "Results are local and limited to indexed Hall-e notes.")
            } else if model.searchResults.isEmpty && !model.isSearching {
                HalleEmptyState(symbol: "doc.text.magnifyingglass", title: "No results", detail: "Try a project, meeting title, or decision keyword.")
            } else {
                List(model.searchResults) { document in
                    Button { model.selection = .document(document.path) } label: {
                        VStack(alignment: .leading, spacing: 3) { Text(document.title); Text(document.path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private extension TimeInterval {
    var formattedDuration: String {
        let total = max(0, Int(self)); return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
