import Foundation
import Observation

enum WorkspaceRoute: String, CaseIterable, Identifiable, Hashable {
    case today, inbox, projects, meetings, actions, people, search
    var id: String { rawValue }

    var title: String { L10n.text("workspace.\(rawValue)") }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .inbox: "tray"
        case .projects: "folder"
        case .meetings: "calendar.badge.clock"
        case .actions: "checklist"
        case .people: "person.2"
        case .search: "magnifyingglass"
        }
    }
}

enum WorkspaceSelection: Hashable {
    case meeting(String), project(String), recording(UUID), action(String), person(String), document(String)
}

enum AttentionSeverity: Int, Comparable {
    case info, warning, error
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct AttentionItem: Identifiable, Hashable {
    enum Kind: String { case classification, transcription, sync, vault, action }
    let id: String
    let kind: Kind
    let severity: AttentionSeverity
    let title: String
    let detail: String
    let selection: WorkspaceSelection?
}

enum ActionBucket: String, CaseIterable, Identifiable {
    case overdue, today, upcoming, unscheduled, completed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ProjectActivityKind: String {
    case meeting, note, codex, chatGPT, whatsApp, snapshot

    var symbol: String {
        switch self {
        case .meeting: "calendar"
        case .note: "doc.text"
        case .codex: "terminal"
        case .chatGPT: "sparkles"
        case .whatsApp: "message.fill"
        case .snapshot: "wand.and.stars"
        }
    }
}

struct ProjectActivityItem: Identifiable, Hashable {
    var id: String
    var kind: ProjectActivityKind
    var title: String
    var detail: String?
    var date: Date
    var selection: WorkspaceSelection?
}

@MainActor
@Observable
final class WorkspaceViewModel {
    let appState: AppState
    var route: WorkspaceRoute = .today
    var selection: WorkspaceSelection?
    var searchQuery = "" { didSet { scheduleSearch() } }
    var searchResults: [VaultDocument] = []
    var isSearching = false
    var searchError: String?
    var directoryRevision = 0
    private var searchTask: Task<Void, Never>?

    init() { self.appState = .shared }
    init(appState: AppState) { self.appState = appState }

    var projects: [Project] { _ = directoryRevision; return AliasStore.shared.projects.filter { !$0.isArchived }.sorted { $0.name < $1.name } }
    var people: [Person] { _ = directoryRevision; return PeopleStore.shared.people.filter { !$0.isArchived }.sorted { $0.name < $1.name } }
    func refreshDirectory() { AliasStore.shared.reload(); PeopleStore.shared.reload(); directoryRevision += 1 }
    var recordings: [RecordingSession] { Array(appState.recordingsByEvent.values).sorted { $0.startedAt > $1.startedAt } }

    func snapshot(for project: Project) -> ProjectSnapshotRecord? {
        appState.projectSnapshots.first { $0.projectId == project.id }
    }

    func sources(for project: Project) -> [ProjectSourceRecord] {
        appState.projectSources.filter { $0.projectId == project.id }
    }

    func sourceDocuments(for project: Project) -> [ProjectSourceDocument] {
        appState.projectSourceDocuments.filter { $0.projectId == project.id }
    }

    func assistantMessages(for project: Project) -> [ProjectAssistantMessageRecord] {
        appState.projectAssistantMessages.filter { $0.projectId == project.id }
    }

    func activity(for project: Project) -> [ProjectActivityItem] {
        var items = appState.agenda.filter { $0.projectId == project.name || $0.projectId == project.id }.map {
            ProjectActivityItem(id: "meeting-\($0.dedupKey)", kind: .meeting, title: $0.title,
                                detail: $0.descriptionText, date: $0.startTs,
                                selection: .meeting($0.dedupKey))
        }
        items += appState.vaultDocuments.filter { $0.project == project.name }.map {
            ProjectActivityItem(id: "note-\($0.path)", kind: .note, title: $0.title,
                                detail: $0.path, date: $0.modifiedAt, selection: .document($0.path))
        }
        items += sourceDocuments(for: project).map {
            let kind: ProjectActivityKind = switch $0.kind {
            case .codex: .codex
            case .chatGPT: .chatGPT
            case .whatsApp: .whatsApp
            case .obsidian: .note
            }
            return ProjectActivityItem(id: "source-\($0.id)", kind: kind, title: $0.title,
                                       detail: $0.author, date: $0.occurredAt ?? $0.importedAt,
                                       selection: nil)
        }
        if let snapshot = snapshot(for: project) {
            items.append(ProjectActivityItem(id: "snapshot-\(snapshot.sourceRevision)", kind: .snapshot,
                                             title: "Project brief refreshed", detail: snapshot.status,
                                             date: snapshot.generatedAt, selection: nil))
        }
        return items.sorted { $0.date > $1.date }
    }

    var attentionItems: [AttentionItem] {
        var result = appState.agenda.filter { $0.projectId == nil && $0.endTs > Date().addingTimeInterval(-86_400) }.map {
            AttentionItem(id: "classify-\($0.dedupKey)", kind: .classification, severity: .warning,
                          title: $0.title, detail: "Assign this meeting to a project.", selection: .meeting($0.dedupKey))
        }
        result += recordings.filter { $0.transcriptStatus == .failed }.map {
            AttentionItem(id: "transcript-\($0.id)", kind: .transcription, severity: .error,
                          title: $0.eventTitle, detail: "Transcription failed. Audio remains safe on this Mac.", selection: .recording($0.id))
        }
        if let error = appState.lastSyncError {
            result.append(AttentionItem(id: "sync", kind: .sync, severity: .error,
                                        title: "Calendar sync needs attention", detail: error, selection: nil))
        }
        result += appState.actionItems.filter { !$0.isCompleted && ($0.project == nil || $0.owner == nil || $0.dueDate == nil) }.map {
            AttentionItem(id: "action-\($0.id)", kind: .action, severity: .info,
                          title: $0.task, detail: "Add project, owner, or due date in its source note.", selection: .action($0.id))
        }
        return result.sorted { $0.severity > $1.severity }
    }

    func badge(for route: WorkspaceRoute) -> Int {
        switch route {
        case .inbox: attentionItems.count
        case .actions: appState.actionItems.filter { !$0.isCompleted }.count
        case .meetings: recordings.filter { $0.transcriptStatus == .failed }.count
        default: 0
        }
    }

    func actions(in bucket: ActionBucket, now: Date = Date()) -> [IndexedActionItem] {
        let cal = Calendar.current
        return appState.actionItems.filter { item in
            if bucket == .completed { return item.isCompleted }
            guard !item.isCompleted else { return false }
            guard let due = Self.dueDate(item.dueDate) else { return bucket == .unscheduled }
            switch bucket {
            case .overdue: return due < cal.startOfDay(for: now)
            case .today: return cal.isDate(due, inSameDayAs: now)
            case .upcoming: return due > now && !cal.isDate(due, inSameDayAs: now)
            case .unscheduled, .completed: return false
            }
        }.sorted { (Self.dueDate($0.dueDate) ?? .distantFuture) < (Self.dueDate($1.dueDate) ?? .distantFuture) }
    }

    private static func dueDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { searchResults = []; isSearching = false; searchError = nil; return }
        isSearching = true; searchError = nil
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let docs = await VaultIndex.shared.search(query, limit: 50)
            guard !Task.isCancelled else { return }
            self?.searchResults = docs
            self?.isSearching = false
        }
    }
}
