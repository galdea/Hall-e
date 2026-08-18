import SwiftUI
import AppKit
import GRDB
import UniformTypeIdentifiers

struct ProjectOverviewDashboard: View {
    let project: Project
    let model: WorkspaceViewModel
    @State private var refreshing = false
    @State private var errorMessage: String?

    private var snapshot: ProjectSnapshotRecord? { model.snapshot(for: project) }
    private var meetings: [UnifiedEvent] {
        model.appState.agenda.filter { $0.projectId == project.name || $0.projectId == project.id }
    }
    private var actions: [IndexedActionItem] {
        model.appState.actionItems.filter { $0.project == project.name && !$0.isCompleted }
    }
    private var notes: [VaultDocument] { model.appState.vaultDocuments.filter { $0.project == project.name } }
    private var nextMeeting: UnifiedEvent? {
        meetings.filter { $0.endTs >= Date() }.sorted { $0.startTs < $1.startTs }.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    MetricPill(value: "\(meetings.count)", label: "meetings")
                    MetricPill(value: "\(actions.count)", label: "open actions")
                    MetricPill(value: "\(notes.count)", label: "notes")
                    MetricPill(value: "\(model.sources(for: project).count)", label: "sources")
                    Spacer()
                    Button { refresh() } label: {
                        if refreshing { ProgressView().controlSize(.small) }
                        else { Label("Refresh brief", systemImage: "arrow.clockwise") }
                    }.disabled(refreshing)
                }

                if let snapshot {
                    HalleCard {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                HalleStatusBadge(text: snapshot.health.replacingOccurrences(of: "-", with: " ").capitalized,
                                                 tone: healthTone(snapshot.health))
                                Text(snapshot.status).font(.headline)
                                Spacer()
                                Text(snapshot.generatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(snapshot.summary).textSelection(.enabled)
                            if let confidence = snapshot.confidence {
                                Text("Assistant confidence: \(confidence.formatted(.percent.precision(.fractionLength(0))))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    HalleCard {
                        HStack {
                            Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading) {
                                Text("No project brief yet").font(.headline)
                                Text("Refresh to build a cited status from linked project data.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack(alignment: .top, spacing: 16) {
                    dashboardSection("Next meeting", symbol: "calendar.badge.clock") {
                        if let nextMeeting {
                            Button { model.selection = .meeting(nextMeeting.dedupKey) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(nextMeeting.title).fontWeight(.medium)
                                    Text(nextMeeting.startTs.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        } else { Text("No upcoming meeting").foregroundStyle(.secondary) }
                    }
                    dashboardSection("Blockers and risks", symbol: "exclamationmark.triangle") {
                        snapshotList((snapshot?.blockers ?? []) + (snapshot?.risks ?? []), empty: "None identified")
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    dashboardSection("Next steps", symbol: "arrow.forward.circle") {
                        snapshotList(snapshot?.nextSteps ?? [], empty: "No generated next steps")
                    }
                    dashboardSection("Suggested agenda", symbol: "list.bullet.clipboard") {
                        snapshotList(snapshot?.agenda ?? [], empty: "No generated agenda")
                    }
                }

                dashboardSection("Recent activity", symbol: "clock.arrow.circlepath") {
                    let activity = Array(model.activity(for: project).prefix(8))
                    if activity.isEmpty { Text("No indexed activity").foregroundStyle(.secondary) }
                    ForEach(activity) { item in
                        ProjectActivityRow(item: item) { if let selection = item.selection { model.selection = selection } }
                    }
                }
            }.padding(20)
        }
    }

    private func dashboardSection<Content: View>(_ title: String, symbol: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        } label: { Label(title, systemImage: symbol) }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func snapshotList(_ values: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if values.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(values, id: \.self) { Label($0, systemImage: "circle.fill").font(.callout) }
        }
    }

    private func healthTone(_ health: String) -> HalleStatusTone {
        switch health.lowercased() {
        case "on-track", "on track": .success
        case "at-risk", "at risk": .warning
        case "blocked": .error
        default: .neutral
        }
    }

    private func refresh() {
        refreshing = true; errorMessage = nil
        Task {
            do { _ = try await ProjectIntelligenceService.shared.refresh(project: project, force: true) }
            catch { errorMessage = error.localizedDescription }
            refreshing = false
        }
    }
}

struct ProjectAssistantView: View {
    let project: Project
    let model: WorkspaceViewModel
    @State private var question = ""
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.assistantMessages(for: project).isEmpty {
                            HalleEmptyState(symbol: "bubble.left.and.text.bubble.right",
                                            title: "Ask about \(project.name)",
                                            detail: "Hall-e answers from cited meetings, notes, Codex sessions, and imported conversations.")
                        }
                        ForEach(model.assistantMessages(for: project)) { message in
                            AssistantMessageBubble(message: message).id(message.id)
                        }
                    }.padding(20)
                }
                .onChange(of: model.assistantMessages(for: project).count) { _, _ in
                    if let last = model.assistantMessages(for: project).last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    quickQuestion("What should I do next?")
                    quickQuestion("Build my next project agenda")
                    quickQuestion("What is at risk?")
                }
                HStack {
                    TextField("Ask the project assistant", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .onSubmit { send() }
                    Button { send() } label: {
                        if sending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    }.buttonStyle(.borderless).disabled(sending || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
                if !LLMProviderConfig.load().allowCloudTranscriptProcessing,
                   ![ProviderKind.ollama, .lmStudio].contains(LLMProviderConfig.load().kind) {
                    Label("Imported conversations and raw transcripts stay out of cloud prompts until enabled in AI settings.",
                          systemImage: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(12)
        }
    }

    private func quickQuestion(_ value: String) -> some View {
        Button(value) { question = value }.buttonStyle(.bordered).controlSize(.small)
    }

    private func send() {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        question = ""; sending = true; errorMessage = nil
        Task {
            do { _ = try await ProjectIntelligenceService.shared.answer(value, project: project) }
            catch { errorMessage = error.localizedDescription }
            sending = false
        }
    }
}

struct AssistantMessageBubble: View {
    let message: ProjectAssistantMessageRecord
    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 5) {
            Text(message.role == "user" ? "You" : "Hall-e").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(message.body).textSelection(.enabled).padding(10)
                .background(message.role == "user" ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 10))
            if !message.citations.isEmpty {
                Text(message.citations.map { "[\($0.id)] \($0.sourceLabel) — \($0.title)" }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }
}

struct ProjectActivityView: View {
    let project: Project
    let model: WorkspaceViewModel
    var body: some View {
        List(model.activity(for: project)) { item in
            ProjectActivityRow(item: item) { if let selection = item.selection { model.selection = selection } }
        }
    }
}

struct ProjectActivityRow: View {
    let item: ProjectActivityItem
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.kind.symbol).foregroundStyle(Color.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).foregroundStyle(.primary)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Text(item.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(item.selection == nil)
    }
}

struct ProjectSourcesView: View {
    let project: Project
    let model: WorkspaceViewModel
    @State private var errorMessage: String?
    @State private var chatGPTPreview: ChatGPTImportPreview?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Link local and exported project context. Every source is isolated to this project.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Link Codex project folder…", action: chooseCodexFolder)
                    Button("Import ChatGPT export…", action: chooseChatGPTExport)
                    Button("Import WhatsApp group export…", action: chooseWhatsAppExport)
                } label: { Label("Add Source", systemImage: "plus") }
            }.padding(12)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if model.sources(for: project).isEmpty {
                HalleEmptyState(symbol: "externaldrive.badge.plus", title: "No linked sources",
                                detail: "Link a Codex folder or import ChatGPT and WhatsApp exports.")
            } else {
                List(model.sources(for: project)) { source in sourceRow(source) }
            }
        }
        .sheet(item: $chatGPTPreview) { preview in
            ChatGPTImportSelectionView(project: project, preview: preview) {
                chatGPTPreview = nil
            }
        }
    }

    private func sourceRow(_ source: ProjectSourceRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: source.kind.symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName).fontWeight(.medium)
                if let location = source.location { Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                HStack {
                    if let date = source.lastImportedAt { Text("Updated \(date.formatted(.relative(presentation: .named)))") }
                    else { Text("Not imported") }
                    if let error = source.lastError { Text("· \(error)").foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("AI", isOn: Binding(get: { source.includeInAI }, set: { update(source, includeInAI: $0) }))
                .toggleStyle(.switch).controlSize(.small).help("Include this source in project assistant context")
            if source.kind == .chatGPT {
                Button(action: chooseChatGPTExport) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Select conversations from a new export")
            } else {
                Button { refresh(source) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh source")
            }
            Button(role: .destructive) { remove(source) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove source and imported documents")
        }.padding(.vertical, 4)
    }

    private func chooseCodexFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Link Project Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { _ = try await ProjectSourceImportCoordinator.shared.linkCodex(projectId: project.id, projectName: project.name, folder: url) }
               catch { errorMessage = error.localizedDescription } }
    }
    private func chooseChatGPTExport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .zip, .plainText]
        panel.allowsMultipleSelection = false; panel.prompt = "Preview Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let documents = try await Task.detached { try ChatGPTExportImporter().load(from: url) }.value
                chatGPTPreview = ChatGPTImportPreview(file: url, documents: documents)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func chooseWhatsAppExport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false; panel.prompt = "Import Chat"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { _ = try await ProjectSourceImportCoordinator.shared.importFile(projectId: project.id, kind: .whatsApp, file: url) }
               catch { errorMessage = error.localizedDescription } }
    }
    private func update(_ source: ProjectSourceRecord, includeInAI: Bool) {
        var updated = source; updated.includeInAI = includeInAI
        let value = updated
        Task {
            try? await AppDatabase.shared.dbQueue.write { db in try value.save(db) }
            await ProjectIntelligenceService.shared.scheduleRefresh(projectId: project.id)
        }
    }
    private func refresh(_ source: ProjectSourceRecord) {
        Task { do { try await ProjectSourceImportCoordinator.shared.refresh(source) }
               catch { errorMessage = error.localizedDescription } }
    }
    private func remove(_ source: ProjectSourceRecord) {
        Task { do { try await ProjectSourceImportCoordinator.shared.remove(source) }
               catch { errorMessage = error.localizedDescription } }
    }
}

struct ChatGPTImportPreview: Identifiable {
    let id = UUID()
    let file: URL
    let documents: [NormalizedProjectDocument]
}

struct ChatGPTImportSelectionView: View {
    let project: Project
    let preview: ChatGPTImportPreview
    let onFinish: () -> Void
    @State private var selected: Set<String>
    @State private var importing = false
    @State private var errorMessage: String?

    init(project: Project, preview: ChatGPTImportPreview, onFinish: @escaping () -> Void) {
        self.project = project; self.preview = preview; self.onFinish = onFinish
        _selected = State(initialValue: Set(preview.documents.map(\.externalId)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Import ChatGPT conversations").font(.title2.weight(.semibold))
                    Text("Choose what becomes context for \(project.name).").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Select none") { selected.removeAll() }
                Button("Select all") { selected = Set(preview.documents.map(\.externalId)) }
            }
            List(preview.documents, id: \.externalId) { document in
                Toggle(isOn: Binding(get: { selected.contains(document.externalId) }, set: {
                    if $0 { selected.insert(document.externalId) } else { selected.remove(document.externalId) }
                })) {
                    VStack(alignment: .leading) {
                        Text(document.title)
                        if let date = document.occurredAt { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.orange) }
            HStack {
                Label("Only selected conversation text is copied into Hall-e.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onFinish)
                Button {
                    importing = true
                    Task {
                        do {
                            let documents = preview.documents.filter { selected.contains($0.externalId) }
                            _ = try await ProjectSourceImportCoordinator.shared.importFile(
                                projectId: project.id, kind: .chatGPT, file: preview.file,
                                selectedDocuments: documents)
                            onFinish()
                        } catch { errorMessage = error.localizedDescription; importing = false }
                    }
                } label: {
                    if importing { ProgressView().controlSize(.small) } else { Text("Import \(selected.count)") }
                }.buttonStyle(.borderedProminent).disabled(importing || selected.isEmpty)
            }
        }.padding(20).frame(width: 720, height: 560)
    }
}
