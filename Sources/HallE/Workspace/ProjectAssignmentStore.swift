import Foundation
import GRDB

enum ManualProjectAssignmentDecision: Equatable {
    case none
    case assigned(String?)
}

/// Pure resolution shared by sync and tests. Per-occurrence choices always win;
/// otherwise the most recent recurring rule at or before the occurrence applies.
enum ProjectAssignmentResolver {
    static func decision(for event: UnifiedEvent,
                         occurrenceAssignments: [String: EventProjectAssignment],
                         recurringAssignments: [RecurringProjectAssignment]) -> ManualProjectAssignmentDecision {
        if let occurrence = occurrenceAssignments[event.dedupKey] {
            return .assigned(occurrence.projectId)
        }

        guard let seriesId = event.iCalUID, !seriesId.isEmpty else { return .none }
        let rule = recurringAssignments
            .filter { $0.seriesId == seriesId && $0.effectiveFrom <= event.startTs }
            .max {
                if $0.effectiveFrom != $1.effectiveFrom { return $0.effectiveFrom < $1.effectiveFrom }
                return $0.updatedAt < $1.updatedAt
            }
        guard let rule else { return .none }
        return .assigned(rule.projectId)
    }
}

struct LocalProjectDecisions {
    var occurrences: [String: EventProjectAssignment] = [:]
    var recurring: [RecurringProjectAssignment] = []

    static func read(_ db: Database) throws -> Self {
        let rows = try EventProjectAssignment.fetchAll(db)
        return .init(occurrences: Dictionary(uniqueKeysWithValues: rows.map { ($0.dedupKey, $0) }),
                     recurring: try RecurringProjectAssignment.fetchAll(db))
    }

    func decision(for event: UnifiedEvent) -> ManualProjectAssignmentDecision {
        ProjectAssignmentResolver.decision(for: event, occurrenceAssignments: occurrences, recurringAssignments: recurring)
    }

    func needsProject(_ event: UnifiedEvent) -> Bool {
        event.projectId == nil && event.status != "cancelled" && decision(for: event) == .none
    }
}

struct LocalProjectSuggestion: Equatable {
    enum Evidence: Equatable {
        case confirmedOccurrences(Int)
        case rule(String)
    }
    let projectID: String
    let name: String
    let evidence: Evidence

    /// History is limited to explicitly confirmed, finished occurrences of this same title
    /// and calendar account. A similar title, a series prediction or a folder name is not confirmation.
    static func evaluate(_ target: UnifiedEvent, history: [UnifiedEvent], decisions: LocalProjectDecisions,
                         projects: [Project], now: Date, recordingIndex: [String: RecordingSession] = [:]) -> Self? {
        guard decisions.needsProject(target), !target.isAllDay else { return nil }
        let title = normalizedTitle(target.title)
        let owner = address(target.winnerAccountEmail)
        guard !title.isEmpty, !owner.isEmpty else { return nil }
        let organizer = address(target.organizerEmail)
        let cutoff = min(now, target.startTs)
        let active = projects.filter { !$0.isArchived }
        let scores = RulesEngine.score(ClassificationInput(from: target), projects: active)
        var matchingIDs: Set<String> = []
        var confirmedProject: Project?
        let live = Dictionary(history.compactMap { event in
            decisions.occurrences[event.dedupKey] == nil ? nil : (event.dedupKey, event)
        }, uniquingKeysWith: { first, _ in first })
        for (key, explicit) in decisions.occurrences {
            guard explicit.updatedAt <= cutoff else { continue }
            let prior: UnifiedEvent
            if let event = live[key] {
                prior = event
            } else if let manifest = recordingIndex[key], manifest.eventDedupKey == key,
                      let snapshot = manifest.eventSnapshot, snapshot.dedupKey == key {
                prior = snapshot
            } else {
                continue
            }
            guard prior.dedupKey != target.dedupKey, prior.status != "cancelled", !prior.isAllDay,
                  prior.startTs < target.startTs, prior.endTs <= cutoff,
                  address(prior.winnerAccountEmail) == owner, address(prior.organizerEmail) == organizer,
                  normalizedTitle(prior.title) == title
            else { continue }
            guard let project = AliasStore.project(resolving: explicit.projectId, in: projects), !project.isArchived,
                  confirmedProject == nil || confirmedProject?.id == project.id else { return nil }
            confirmedProject = project
            matchingIDs.insert(prior.dedupKey)
        }
        if let confirmedProject {
            guard matchingIDs.count >= (organizer.isEmpty ? 2 : 1),
                  !scores.contains(where: { $0.value >= RulesEngine.inboxThreshold && $0.project.id != confirmedProject.id })
            else { return nil }
            return .init(projectID: confirmedProject.id, name: confirmedProject.name, evidence: .confirmedOccurrences(matchingIDs.count))
        }
        guard let top = scores.first, top.value >= RulesEngine.inboxThreshold, let reason = top.reasons.first,
              top.value - (scores.dropFirst().first?.value ?? 0) >= RulesEngine.ambiguityGap else { return nil }
        return .init(projectID: top.project.id, name: top.project.name, evidence: .rule(reason))
    }

    static func normalizedTitle(_ title: String) -> String {
        TextNormalizer.fold(title).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func address(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Persists explicit meeting → project choices. Assignment rows store stable
/// project IDs, while `UnifiedEvent.projectId` remains a display name for legacy
/// consumers such as recordings and Obsidian note paths.
struct ProjectAssignmentStore {
    static let shared = ProjectAssignmentStore(database: .shared, aliasStore: .shared)

    let database: AppDatabase
    let aliasStore: AliasStore
    let didAssign: () async -> Void

    init(database: AppDatabase, aliasStore: AliasStore,
         didAssign: @escaping () async -> Void = { await ProjectIntelligenceService.shared.scheduleRefreshAll() }) {
        self.database = database
        self.aliasStore = aliasStore
        self.didAssign = didAssign
    }

    func assign(projectID: String?, to event: UnifiedEvent, rememberFuture: Bool) async throws {
        try await save(projectID: projectID, to: event, rememberFuture: rememberFuture, suggestionProjects: nil, recordingIndex: [:])
        await didAssign()
    }

    func confirm(_ suggestion: LocalProjectSuggestion, for event: UnifiedEvent, rememberFuture: Bool,
                 classificationProjects: [Project], recordingIndex: [String: RecordingSession] = [:]) async throws {
        try await save(projectID: suggestion.projectID, to: event, rememberFuture: rememberFuture,
                       suggestionProjects: classificationProjects, recordingIndex: recordingIndex)
        // Confirming a local suggestion must not schedule provider-backed project summaries.
    }

    private func save(projectID: String?, to event: UnifiedEvent, rememberFuture: Bool,
                      suggestionProjects: [Project]?, recordingIndex: [String: RecordingSession]) async throws {
        let projects = aliasStore.projects
        if let projectID, AliasStore.project(resolving: projectID, in: projects) == nil {
            throw ProjectAssignmentError.unknownProject(projectID)
        }

        let canonicalID = projectID.flatMap { AliasStore.project(resolving: $0, in: projects)?.id }
        let now = Date()
        try await database.dbQueue.write { db in
            if let suggestionProjects {
                guard let current = try UnifiedEvent.fetchOne(db, key: event.dedupKey), current == event else {
                    throw ProjectAssignmentError.suggestionChanged
                }
                let decisions = try LocalProjectDecisions.read(db)
                let confirmedHistory = try UnifiedEvent.fetchAll(db, sql: """
                    SELECT u.* FROM unified_event u JOIN event_project_assignment a USING (dedupKey)
                    WHERE a.updatedAt <= ?
                    """, arguments: [min(now, current.startTs)])
                let candidate = LocalProjectSuggestion.evaluate(current, history: confirmedHistory, decisions: decisions,
                                                               projects: suggestionProjects, now: now, recordingIndex: recordingIndex)
                guard candidate?.projectID == canonicalID, canonicalID != nil,
                      projects.contains(where: { $0.id == canonicalID && !$0.isArchived }) else {
                    throw ProjectAssignmentError.suggestionChanged
                }
            }
            let occurrence = EventProjectAssignment(dedupKey: event.dedupKey,
                                                      projectId: canonicalID,
                                                      updatedAt: now)
            try occurrence.save(db)

            if rememberFuture {
                guard let seriesId = event.iCalUID, !seriesId.isEmpty,
                      try Self.isRecurring(event, in: db) else {
                    throw ProjectAssignmentError.notRecurring
                }
                let recurring = RecurringProjectAssignment(seriesId: seriesId,
                                                            effectiveFrom: event.startTs,
                                                            projectId: canonicalID,
                                                            updatedAt: now)
                try recurring.save(db)
            }

            try Self.refreshCachedEvents(in: db,
                                         projects: projects,
                                         limitingSeriesTo: rememberFuture ? event.iCalUID : nil,
                                         limitingEventTo: rememberFuture ? nil : event.dedupKey)
        }
    }

    func isRecurring(_ event: UnifiedEvent) async throws -> Bool {
        try await database.dbQueue.read { try Self.isRecurring(event, in: $0) }
    }

    private static func isRecurring(_ event: UnifiedEvent, in db: Database) throws -> Bool {
        guard let uid = event.iCalUID, !uid.isEmpty else { return false }
        return try CalendarEvent.filter(sql: "iCalUID = ? AND originalStartTs IS NOT NULL", arguments: [uid]).fetchCount(db) > 0
    }

    /// Rewrites cached display names after a project rename and reapplies manual
    /// stable-ID assignments. Historical aliases keep legacy assignment rows valid.
    func refreshDisplayName(projectID: String, previousName: String?) async throws {
        let projects = aliasStore.projects
        guard let project = AliasStore.project(resolving: projectID, in: projects) else {
            throw ProjectAssignmentError.unknownProject(projectID)
        }

        try await database.dbQueue.write { db in
            if let previousName, !previousName.isEmpty, previousName != project.name {
                try db.execute(sql: "UPDATE unified_event SET projectId = ? WHERE projectId = ? OR projectId = ?",
                               arguments: [project.name, previousName, projectID])
            }
            try Self.refreshCachedEvents(in: db, projects: projects)
        }
    }

    private static func refreshCachedEvents(in db: Database,
                                            projects: [Project],
                                            limitingSeriesTo seriesId: String? = nil,
                                            limitingEventTo dedupKey: String? = nil) throws {
        let occurrenceAssignments = Dictionary(uniqueKeysWithValues:
            try EventProjectAssignment.fetchAll(db).map { ($0.dedupKey, $0) })
        let recurringAssignments = try RecurringProjectAssignment.fetchAll(db)

        let events: [UnifiedEvent]
        if let dedupKey {
            events = try UnifiedEvent.filter(UnifiedEvent.Columns.dedupKey == dedupKey).fetchAll(db)
        } else if let seriesId {
            events = try UnifiedEvent.filter(sql: "iCalUID = ?", arguments: [seriesId]).fetchAll(db)
        } else {
            events = try UnifiedEvent.fetchAll(db)
        }

        for var event in events {
            guard case let .assigned(reference) = ProjectAssignmentResolver.decision(
                for: event,
                occurrenceAssignments: occurrenceAssignments,
                recurringAssignments: recurringAssignments
            ) else { continue }
            event.projectId = reference.flatMap { AliasStore.project(resolving: $0, in: projects)?.name ?? $0 }
            event.projectConfidence = reference == nil ? nil : 1.0
            try event.update(db)
        }
    }
}

enum ProjectAssignmentError: LocalizedError {
    case unknownProject(String)
    case notRecurring
    case suggestionChanged

    var errorDescription: String? {
        switch self {
        case let .unknownProject(reference): "Project “\(reference)” no longer exists."
        case .suggestionChanged: PublicUICopy.text("The project suggestion changed. Review the current meeting before assigning it.", "La sugerencia de proyecto cambió. Revisa la reunión antes de asignarla.")
        case .notRecurring: "This meeting is not part of a recurring calendar series."
        }
    }
}
