import SwiftUI
import AppKit
import GRDB

struct SyncHealthButton: View {
    @State private var appState = AppState.shared
    var body: some View {
        Button { Task { await SyncCoordinator.shared.syncAll() } } label: {
            if appState.isSyncing { ProgressView().controlSize(.small) }
            else { Image(systemName: appState.lastSyncError == nil ? "arrow.clockwise" : "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(appState.lastSyncError == nil ? Color.secondary : Color.orange) }
        }
        .disabled(appState.isSyncing).help(appState.lastSyncError ?? L10n.text("common.refresh"))
    }
}

struct MeetingInspectorView: View {
    let event: UnifiedEvent
    let model: WorkspaceViewModel
    @State private var showProjectChooser = false
    @State private var appState = AppState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HalleUI.sectionSpacing) {
                VStack(alignment: .leading, spacing: 7) {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        HStack {
                            HalleStatusBadge(text: stateLabel(now: context.date), tone: stateTone(now: context.date))
                            Spacer(); Text(relativeText(now: context.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(event.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(event.startTs.formatted(date: .abbreviated, time: .shortened) + " – " + event.endTs.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                    MeetingActionButtons(event: event)
                }

                inspectorSection("Project", symbol: "folder") {
                    Button { showProjectChooser = true } label: {
                        Label(AliasStore.shared.projectName(for: event.projectId) ?? event.projectId ?? "Choose project…", systemImage: "folder.badge.gearshape")
                    }
                    if let confidence = event.projectConfidence { Text("Classification confidence: \(confidence.formatted(.percent.precision(.fractionLength(0))))").font(.caption).foregroundStyle(.secondary) }
                }

                if !event.attendees.isEmpty {
                    inspectorSection("Attendees", symbol: "person.2") {
                        ForEach(event.attendees, id: \.email) { attendee in
                            HStack { Image(systemName: "person.crop.circle").foregroundStyle(.secondary); Text(attendee.name ?? attendee.email ?? "Guest") }
                        }
                    }
                }

                if let session = appState.recordingsByEvent[event.dedupKey] {
                    inspectorSection("Recording", symbol: "waveform") {
                        HStack { HalleStatusBadge(text: session.transcriptStatus.rawValue, tone: transcriptTone(session.transcriptStatus)); Spacer(); Text(session.startedAt, style: .time).foregroundStyle(.secondary) }
                        if session.transcriptStatus == .failed {
                            TranscriptionRecoveryControls(session: session)
                        }
                        RecordingTransportView(session: session)
                        if session.transcriptStatus == .completed { TranscriptReaderView(session: session) }
                    }
                }

                let meetingProject = AliasStore.shared.project(resolving: event.projectId)
                let related = model.appState.actionItems.filter { action in
                    action.eventId == event.dedupKey || (meetingProject.map {
                        AliasStore.shared.references(action.project, project: $0)
                    } ?? false)
                }
                inspectorSection("Open commitments", symbol: "checklist") {
                    if related.isEmpty { Text("No indexed commitments").foregroundStyle(.secondary) }
                    ForEach(related.prefix(8)) { Text($0.task).font(.callout) }
                }

                if let description = event.descriptionText, !description.isEmpty {
                    inspectorSection("Calendar context", symbol: "text.alignleft") {
                        Text(description).font(.callout).textSelection(.enabled).lineLimit(12)
                    }
                }
            }.padding(20)
        }.navigationTitle("Meeting")
        .sheet(isPresented: $showProjectChooser) {
            MeetingProjectChooser(event: event) { model.refreshDirectory() }
        }
    }

    private func inspectorSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stateLabel(now: Date) -> String { event.startTs <= now && now < event.endTs ? L10n.text("agenda.now") : event.startTs > now ? L10n.text("agenda.next") : "Ended" }
    private func stateTone(now: Date) -> HalleStatusTone { event.startTs <= now && now < event.endTs ? .recording : event.startTs > now ? .info : .neutral }
    private func relativeText(now: Date) -> String { (event.startTs > now ? event.startTs : event.endTs).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) }
    private func transcriptTone(_ status: TranscriptStatus) -> HalleStatusTone { switch status { case .completed: .success; case .failed: .error; case .inProgress, .pending: .warning } }
}

struct ProjectDetailView: View {
    enum Tab: String, CaseIterable {
        case overview = "Overview", assistant = "Assistant", activity = "Activity"
        case meetings = "Meetings", actions = "Actions", notes = "Notes"
        case sources = "Sources", rules = "Rules"
    }
    let project: Project
    let model: WorkspaceViewModel
    @State private var tab: Tab = .overview
    @State private var showPreview = false
    private var documents: [VaultDocument] { model.appState.vaultDocuments.filter { AliasStore.shared.references($0.project, project: project) } }
    private var actions: [IndexedActionItem] { model.appState.actionItems.filter { AliasStore.shared.references($0.project, project: project) } }
    private var meetings: [UnifiedEvent] { model.appState.agenda.filter { AliasStore.shared.references($0.projectId, project: project) }.sorted { $0.startTs > $1.startTs } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name).font(.largeTitle.weight(.semibold))
                        if let snapshot = model.snapshot(for: project) {
                            Text(snapshot.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button { showPreview = true } label: {
                        Label("Export context", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.bordered)
                    if LLMProviderConfig.load().useAI {
                        Button { tab = .assistant } label: {
                            Label("Ask Hall-e", systemImage: "sparkles")
                        }.buttonStyle(.borderedProminent)
                    }
                }
                HStack {
                    Picker("Project section", selection: $tab) {
                        ForEach([Tab.overview, .meetings, .notes, .actions], id: \.self) { Text($0.rawValue).tag($0) }
                        if [.assistant, .activity, .sources, .rules].contains(tab) { Text(tab.rawValue).tag(tab) }
                    }.pickerStyle(.segmented)
                    Menu("More") {
                        Button("Activity") { tab = .activity }
                        Button("Connected sources") { tab = .sources }
                        Button("Project matching rules") { tab = .rules }
                    }
                }
            }.padding(20)
            Divider(); projectContent
        }
        .sheet(isPresented: $showPreview) { ChatGPTPrivacyPreview(project: project, documents: model.appState.vaultDocuments, actions: model.appState.actionItems) }
    }
    @ViewBuilder private var projectContent: some View {
        switch tab {
        case .overview:
            ProjectOverviewDashboard(project: project, model: model)
        case .assistant:
            ProjectAssistantView(project: project, model: model)
        case .activity:
            ProjectActivityView(project: project, model: model)
        case .meetings:
            List(meetings) { event in EventRowView(event: event) { model.selection = .meeting($0.dedupKey) } }
        case .actions:
            List(actions) { item in
                Button { model.selection = .action(item.id) } label: {
                    Label(item.task, systemImage: item.isCompleted ? "checkmark.circle.fill" : "circle")
                }.buttonStyle(.plain)
            }
        case .notes:
            List(documents) { document in
                Button { model.selection = .document(document.path) } label: {
                    VStack(alignment: .leading) {
                        Text(document.title); Text(document.path).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        case .sources:
            ProjectSourcesView(project: project, model: model)
        case .rules: List(project.aliases, id: \.self) { alias in HStack { VStack(alignment: .leading) { Text(alias.text); Text(alias.kind.displayLabel).font(.caption).foregroundStyle(.secondary) }; Spacer(); HalleStatusBadge(text: alias.strength.rawValue.capitalized) } }
        }
    }
}

struct ChatGPTPrivacyPreview: View {
    let project: Project
    let documents: [VaultDocument]
    let actions: [IndexedActionItem]
    @Environment(\.dismiss) private var dismiss
    @State private var options = ProjectContextExportOptions()
    @State private var exportError: String?
    private let service = ProjectContextService()
    private var preview: ProjectContextPreview { service.preview(project: project, documents: documents, actions: actions, options: options) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "hand.raised.fill").font(.title).foregroundStyle(Color.accentColor); VStack(alignment: .leading) { Text(L10n.text("chatgpt.preview")).font(.title2.weight(.semibold)); Text(project.name).foregroundStyle(.secondary) }; Spacer() }
            HalleCard { VStack(alignment: .leading, spacing: 8) {
                Label("\(preview.documentCount) cited notes", systemImage: "doc.text")
                Label("\(preview.actionCount) open actions", systemImage: "checklist")
                Label("Approximately \(preview.characterCount.formatted()) characters", systemImage: "textformat.abc")
                Label(L10n.text("chatgpt.rawOff"), systemImage: "lock.fill").foregroundStyle(.green)
            } }
            Toggle("Include project notes", isOn: $options.includeNotes)
            Toggle("Include open actions", isOn: $options.includeActions)
            Toggle("Include raw transcript sections", isOn: $options.includeTranscripts).tint(.red)
            if options.includeTranscripts { Label("Raw transcripts can contain sensitive conversation details.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
            if let exportError { Text(exportError).foregroundStyle(.red).font(.caption) }
            Spacer()
            HStack {
                Button(L10n.text("common.cancel")) { dismiss() }
                Spacer()
                Button(L10n.text("chatgpt.reveal")) { revealPack() }
                Button(L10n.text("chatgpt.copyPrompt")) { copyPrompt() }
                Button(L10n.text("chatgpt.open")) { copyPrompt(); NSWorkspace.shared.open(URL(string: "https://chatgpt.com")!) }.buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(width: 560, height: 470)
    }
    private func text() -> String { service.markdown(project: project, documents: documents, actions: actions, options: options) }
    private func copyPrompt() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("Analyze this project using only the cited Hall-e context below. Distinguish facts from inferences.\n\n" + text(), forType: .string) }
    private func revealPack() { do { let url = try service.writePack(project: project, documents: documents, actions: actions, options: options); NSWorkspace.shared.activateFileViewerSelecting([url]); exportError = nil } catch { exportError = error.localizedDescription } }
}

struct RecordingDetailView: View {
    let session: RecordingSession
    let onDelete: () -> Void
    @State private var confirmsDeletion = false
    @State private var deletionError: String?
    @State private var recorder = RecordingService.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(session.eventTitle).font(.title2.weight(.semibold)); HalleStatusBadge(text: session.transcriptStatus.rawValue, tone: session.transcriptStatus == .failed ? .error : session.transcriptStatus == .completed ? .success : .warning)
                LabeledContent("Started", value: session.startedAt.formatted(date: .abbreviated, time: .shortened)); LabeledContent("Audio", value: session.micFileName)
                if let note = session.notePath { LabeledContent("Note", value: note) }
                if recorder.currentSession?.id == session.id && recorder.isRecording {
                    HStack {
                        Label(PublicUICopy.text("Recording · \(recorder.elapsed.formattedDuration)", "Grabando · \(recorder.elapsed.formattedDuration)"), systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                        Spacer()
                        Button(PublicUICopy.text("Stop recording", "Detener grabación")) { recorder.stop() }
                            .buttonStyle(.borderedProminent).tint(.red)
                    }
                } else {
                    RecordingTransportView(session: session)
                }
                MeetingNotesView(session: session).id(session.id)
                Divider()
                if session.isFinished { TranscriptReaderView(session: session) }
                HStack {
                    Button("Reveal recording folder") { NSWorkspace.shared.activateFileViewerSelecting([session.folderURL]) }
                    Spacer()
                    Button("Delete Audio…", role: .destructive) { confirmsDeletion = true }
                        .disabled(recorder.currentSession?.id == session.id && !session.isFinished)
                }
                if let deletionError { Text(deletionError).font(.caption).foregroundStyle(.red) }
            }.padding(20)
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmsDeletion) {
            Button("Delete Audio", role: .destructive) { deleteRecording() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the audio and transcript files from this Mac. The meeting note is kept.")
        }
    }

    private func deleteRecording() {
        do {
            try RecordingDeletionService.delete(session)
            onDelete()
        } catch {
            deletionError = error.localizedDescription
        }
    }
}

struct ActionDetailView: View {
    let action: IndexedActionItem
    var body: some View { Form { Section("Action") { Text(action.task).font(.title3); LabeledContent("Status", value: action.isCompleted ? "Completed" : "Open"); if let project = action.project { LabeledContent("Project", value: project) }; if let owner = action.owner { LabeledContent("Owner", value: owner) }; if let due = action.dueDate { LabeledContent("Due", value: due) } }; Section("Source") { Text(action.notePath).font(.caption).textSelection(.enabled); Button("Reveal source note") { revealVaultPath(action.notePath) } } }.formStyle(.grouped) }
}

struct PersonDetailView: View {
    let person: Person; let projects: [Project]
    var body: some View { Form { Section { Text(person.name).font(.title2.weight(.semibold)); ForEach(person.emails, id: \.self) { Label($0, systemImage: "envelope") }; ForEach(person.phones, id: \.self) { Label($0, systemImage: "phone") } }; Section("Projects") { ForEach(projects.filter { person.projectIds.contains($0.id) }) { Label($0.name, systemImage: "folder") } }; if let notes = person.notes { Section("Notes") { Text(notes) } }; Section { Text("Edit contact and classification signals in the People editor coming with stable database records.").font(.caption).foregroundStyle(.secondary) } }.formStyle(.grouped) }
}

struct VaultDocumentDetailView: View {
    let document: VaultDocument
    var body: some View { VStack(alignment: .leading, spacing: 12) { HStack { VStack(alignment: .leading) { Text(document.title).font(.title2.weight(.semibold)); Text(document.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Open") { revealVaultPath(document.path) } }; Divider(); ScrollView { Text(document.body).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }.padding(20) }
}

@MainActor private func revealVaultPath(_ relative: String) {
    guard let root = VaultAccess.currentVaultURL() else { return }
    NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(ObsidianVaultConfig.load()?.subfolderName ?? "Hall-e").appendingPathComponent(relative)])
}
