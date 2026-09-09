import Foundation
import Testing
import GRDB
@testable import HallE

@Suite("Project assignments")
struct ProjectAssignmentTests {
    private func event(_ key: String, at time: Double, series: String? = "series") -> UnifiedEvent {
        UnifiedEvent(dedupKey: key, title: "Meeting", startTs: Date(timeIntervalSince1970: time),
                     endTs: Date(timeIntervalSince1970: time + 60), isAllDay: false,
                     status: "confirmed", winnerAccountEmail: "test@example.com", sourcesJSON: "[]")
            .withSeries(series)
    }

    @Test func occurrenceOverridesRulesIncludingUnclassified() {
        let e = event("current", at: 200)
        let rules = [RecurringProjectAssignment(seriesId: "series", effectiveFrom: Date(timeIntervalSince1970: 100), projectId: "one", updatedAt: Date())]
        #expect(ProjectAssignmentResolver.decision(for: e, occurrenceAssignments: [:], recurringAssignments: rules) == .assigned("one"))
        let override = EventProjectAssignment(dedupKey: e.id, projectId: nil, updatedAt: Date())
        #expect(ProjectAssignmentResolver.decision(for: e, occurrenceAssignments: [e.id: override], recurringAssignments: rules) == .assigned(nil))
        #expect(ProjectAssignmentResolver.decision(for: event("past", at: 50), occurrenceAssignments: [:], recurringAssignments: rules) == .none)
        #expect(ProjectAssignmentResolver.decision(for: event("other", at: 200, series: "other"), occurrenceAssignments: [:], recurringAssignments: rules) == .none)
        let later = RecurringProjectAssignment(seriesId: "series", effectiveFrom: Date(timeIntervalSince1970: 150), projectId: nil, updatedAt: Date())
        #expect(ProjectAssignmentResolver.decision(for: e, occurrenceAssignments: [:], recurringAssignments: rules + [later]) == .assigned(nil))
    }

    @Test func createRenameAndWriteFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("projects.json")
        let aliases = AliasStore(fileURL: file, seed: [])
        let created = try aliases.createProject(named: "  Alpha  ")
        #expect(try aliases.createProject(named: "alpha").id == created.id)
        var renamed = created
        renamed.name = "Beta"
        try aliases.updateThrowing(renamed)
        renamed.name = "Gamma"
        renamed.aliases = []
        try aliases.updateThrowing(renamed)
        let reopened = AliasStore(fileURL: file, seed: [])
        #expect(reopened.projectID(for: "Alpha") == created.id)
        #expect(reopened.projectName(for: created.id) == "Gamma")
        #expect(reopened.projectID(for: "Beta") == created.id)
        try FileManager.default.removeItem(at: directory)
        #expect(throws: (any Error).self) { try aliases.createProject(named: "Unsaved") }
        #expect(aliases.project(named: "Unsaved") == nil)
    }

    @Test func historicalReferencesRemainPartOfProjectContext() {
        let project = Project(id: "p1", name: "New name", aliases: [ProjectAlias("Old name", .projectName, .strong)])
        #expect(project.matchesReference("Old name"))
        #expect(project.matchesReference("p1"))
        #expect(project.matchesReference("New name"))
        #expect(!project.matchesReference("Other project"))
        #expect(!project.matchesReference(nil))
    }

    @Test func persistenceRulesRenameAndSyncResolution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aliases = AliasStore(fileURL: directory.appendingPathComponent("projects.json"), seed: [])
        let project = try aliases.createProject(named: "Alpha")
        let database = try AppDatabase(inMemory: true)
        let store = ProjectAssignmentStore(database: database, aliasStore: aliases, didAssign: {})
        let current = event("current", at: 200)
        let future = event("future", at: 300)
        let pinned = event("pinned", at: 400)
        let past = event("past", at: 100)
        try await database.dbQueue.write { db in
            for e in [current, future, pinned, past] { try e.insert(db) }
            try db.execute(sql: "INSERT INTO calendar_event (accountEmail, calendarId, eventId, iCalUID, startTs, endTs, originalStartTs, fetchedAt) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", arguments: ["a", "c", "e", "series", current.startTs, current.endTs, current.startTs, Date()])
        }
        try await store.assign(projectID: project.id, to: current, rememberFuture: false)
        let untouched = try await database.dbQueue.read { try UnifiedEvent.fetchOne($0, key: future.id) }
        #expect(untouched?.projectId == nil)
        let noRules = try await database.dbQueue.read { try RecurringProjectAssignment.fetchCount($0) }
        #expect(noRules == 0)
        try await store.assign(projectID: nil, to: pinned, rememberFuture: false)
        try await store.assign(projectID: project.name, to: current, rememberFuture: true)
        let rows = try await database.dbQueue.read { db in
            (try EventProjectAssignment.fetchOne(db, key: current.id), try UnifiedEvent.fetchAll(db))
        }
        #expect(rows.0?.projectId == project.id)
        #expect(rows.1.first { $0.id == future.id }?.projectId == "Alpha")
        #expect(rows.1.first { $0.id == pinned.id }?.projectId == nil)
        #expect(rows.1.first { $0.id == past.id }?.projectId == nil)
        var renamed = project
        renamed.name = "Beta"
        try aliases.updateThrowing(renamed)
        try await store.refreshDisplayName(projectID: project.id, previousName: "Alpha")
        let rebuilt = try await database.dbQueue.read { db in
            let assignments = Dictionary(uniqueKeysWithValues: try EventProjectAssignment.fetchAll(db).map { ($0.dedupKey, $0) })
            return ProjectAssignmentResolver.decision(for: future, occurrenceAssignments: assignments, recurringAssignments: try RecurringProjectAssignment.fetchAll(db))
        }
        #expect(rebuilt == .assigned(project.id))
        let cached = try await database.dbQueue.read { try UnifiedEvent.fetchOne($0, key: future.id) }
        #expect(cached?.projectId == "Beta")
        let standalone = event("standalone", at: 500, series: "single-uid")
        #expect(try await store.isRecurring(standalone) == false)
        do {
            try await store.assign(projectID: project.id, to: standalone, rememberFuture: true)
            Issue.record("Expected rejection for nonrecurring meeting")
        } catch { }
        let rejected = try await database.dbQueue.read { try EventProjectAssignment.fetchOne($0, key: standalone.id) }
        #expect(rejected == nil)
    }
}

private extension UnifiedEvent {
    func withSeries(_ series: String?) -> UnifiedEvent {
        var copy = self
        copy.iCalUID = series
        return copy
    }
}
