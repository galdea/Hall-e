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
        let projects = aliasStore.projects
        if let projectID, AliasStore.project(resolving: projectID, in: projects) == nil {
            throw ProjectAssignmentError.unknownProject(projectID)
        }

        let canonicalID = projectID.flatMap { AliasStore.project(resolving: $0, in: projects)?.id }
        let now = Date()
        try await database.dbQueue.write { db in
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

        await didAssign()
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

    var errorDescription: String? {
        switch self {
        case let .unknownProject(reference): "Project “\(reference)” no longer exists."
        case .notRecurring: "This meeting is not part of a recurring calendar series."
        }
    }
}
