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

    @Test func suggestionsUseOnlyCompletedConfirmedHistoryWithMatchingContext() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let project = Project(id: "p-1", name: "New project name", aliases: [ProjectAlias("Old project name", .projectName)])
        var target = event("target", at: 2000, series: nil)
        target.title = "  REVÍSION   semanal  "
        target.organizerEmail = "owner@example.invalid"
        var prior = event("previous", at: 100, series: nil)
        prior.title = "Revision semanal"
        prior.organizerEmail = "Owner@example.invalid"
        let choice = EventProjectAssignment(dedupKey: prior.id, projectId: "Old project name", updatedAt: now)
        var rules = LocalProjectDecisions(occurrences: [prior.id: choice])
        func suggest(_ historical: [UnifiedEvent], project candidate: Project? = nil) -> LocalProjectSuggestion? {
            LocalProjectSuggestion.evaluate(target, history: historical, decisions: rules, projects: [candidate ?? project], now: now)
        }
        let suggested = try #require(suggest([prior]))
        #expect(suggested.projectID == project.id && suggested.name == project.name)
        #expect(suggested.evidence == .confirmedOccurrences(1))
        var other = prior
        other.winnerAccountEmail = "another@example.invalid"
        #expect(suggest([other]) == nil)
        other = prior
        other.organizerEmail = "different@example.invalid"
        #expect(suggest([other]) == nil)
        other = prior
        other.title += " extendida"
        #expect(suggest([other]) == nil)
        other = prior
        other.endTs = now.addingTimeInterval(1)
        #expect(suggest([other]) == nil)
        rules.occurrences[prior.id]?.updatedAt = now.addingTimeInterval(1)
        #expect(suggest([prior]) == nil)
        rules.occurrences[prior.id] = nil
        prior.projectId = project.name // A classifier label alone is not manual evidence.
        #expect(suggest([prior]) == nil)
        rules.occurrences[prior.id] = choice
        var archived = project
        archived.isArchived = true
        #expect(suggest([prior], project: archived) == nil)
        target.organizerEmail = nil
        prior.organizerEmail = nil
        #expect(suggest([prior, prior]) == nil)
        other = prior
        other.dedupKey = "second-occurrence"
        rules.occurrences[other.id] = .init(dedupKey: other.id, projectId: project.id, updatedAt: now)
        #expect(suggest([prior, other])?.evidence == .confirmedOccurrences(2))
    }

    @Test func conflictingHistoryAbstainsAndExplicitUnassignedStaysOutOfInbox() throws {
        var target = event("target", at: 2000)
        var prior = event("first", at: 500)
        var other = event("second", at: 600)
        let project = Project(id: "p", name: "One", aliases: [])
        let competing = Project(id: "q", name: "Two", aliases: [.init("meeting", .keyword)])
        let now = Date(timeIntervalSince1970: 1000)
        target.organizerEmail = "person@example.invalid"
        prior.organizerEmail = target.organizerEmail
        other.organizerEmail = target.organizerEmail
        var decisions = LocalProjectDecisions()
        func suggest() -> LocalProjectSuggestion? {
            LocalProjectSuggestion.evaluate(target, history: [prior, other], decisions: decisions, projects: [project, competing], now: now)
        }
        #expect(suggest()?.projectID == competing.id) // Keyword rule, no consulted provider.
        decisions.occurrences[prior.id] = .init(dedupKey: prior.id, projectId: project.id, updatedAt: now)
        #expect(suggest() == nil) // History disagrees with the rule.
        decisions.occurrences[other.id] = .init(dedupKey: other.id, projectId: competing.id, updatedAt: now)
        let neutral = Project(id: competing.id, name: competing.name, aliases: [])
        func historyOnly() -> LocalProjectSuggestion? {
            LocalProjectSuggestion.evaluate(target, history: [prior, other], decisions: decisions, projects: [project, neutral], now: now)
        }
        #expect(historyOnly() == nil)
        decisions.occurrences[other.id]?.projectId = nil
        #expect(historyOnly() == nil)
        decisions.occurrences[target.id] = .init(dedupKey: target.id, projectId: nil, updatedAt: now)
        #expect(!decisions.needsProject(target))
        #expect(suggest() == nil)
        decisions.occurrences[target.id] = nil
        decisions.recurring = [.init(seriesId: "series", effectiveFrom: now, projectId: nil, updatedAt: now)]
        #expect(!decisions.needsProject(target))
        decisions.occurrences[prior.id] = nil
        #expect(decisions.needsProject(prior))
    }

    @Test func purgedOccurrenceUsesItsOwnVerifiedRecordingSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aliases = AliasStore(fileURL: directory.appendingPathComponent("aliases.json"), seed: [])
        let project = try aliases.createProject(named: "Synthetic project")
        let database = try AppDatabase(inMemory: true)
        let store = ProjectAssignmentStore(database: database, aliasStore: aliases, didAssign: { Issue.record("Unexpected summary refresh") })
        var old = event("purged", at: 200, series: nil)
        var current = event("active", at: 2000, series: nil)
        old.organizerEmail = "owner@example.invalid"
        current.organizerEmail = old.organizerEmail
        let target = current
        var manifest = RecordingSession(event: old, notePath: nil)
        let choice = EventProjectAssignment(dedupKey: old.id, projectId: project.id, updatedAt: Date(timeIntervalSince1970: 500))
        let decisions = LocalProjectDecisions(occurrences: [old.id: choice])
        func suggestion(live: [UnifiedEvent] = [], index: [String: RecordingSession]) -> LocalProjectSuggestion? {
            LocalProjectSuggestion.evaluate(target, history: live, decisions: decisions, projects: aliases.projects, now: Date(), recordingIndex: index)
        }
        #expect(suggestion(index: [:]) == nil)
        let candidate = try #require(suggestion(index: [old.id: manifest]))
        #expect(candidate.evidence == .confirmedOccurrences(1))
        #expect(suggestion(live: [old], index: [old.id: manifest])?.evidence == .confirmedOccurrences(1))
        var cancelled = old
        cancelled.status = "cancelled"
        #expect(suggestion(live: [cancelled], index: [old.id: manifest]) == nil)
        try await database.dbQueue.write { db in try choice.insert(db); try target.insert(db) }
        try await store.confirm(candidate, for: target, rememberFuture: false, classificationProjects: aliases.projects,
                                recordingIndex: [old.id: manifest])
        let saved = try await database.dbQueue.read { try LocalProjectDecisions.read($0).decision(for: target) }
        #expect(saved == .assigned(project.id))
        manifest.eventSnapshot = target
        #expect(suggestion(index: [old.id: manifest]) == nil)
    }

    @Test func localProjectViewsResolveArchivedRecordingsWithoutChangingManifests() {
        let original = Project(id: "original", name: "Old space", aliases: [])
        let chosen = Project(id: "stable-id", name: "Renamed space", aliases: [ProjectAlias("Previous name", .projectName)])
        var prior = event("archived", at: 100, series: nil)
        prior.projectId = original.name
        var session = RecordingSession(event: prior, notePath: "fixture/note.md")
        session.state = .completed
        var decisions = LocalProjectDecisions()
        let projects = [original, chosen]
        func view(agenda: [UnifiedEvent] = []) -> WorkspaceProjectMeetings {
            WorkspaceProjectMeetings(agenda: agenda, recordings: [prior.id: session], decisions: decisions, projects: projects)
        }
        #expect(view().recordingProjectNames[session.id] == original.name)
        decisions.occurrences[prior.id] = .init(dedupKey: prior.id, projectId: chosen.id, updatedAt: .now)
        let corrected = view()
        #expect(corrected.archived[chosen.id]?.map(\.id) == [session.id])
        #expect(corrected.recordingProjectNames[session.id] == chosen.name)
        #expect(corrected.count(for: chosen) == 1 && corrected.count(for: original) == 0)
        let live = view(agenda: [prior])
        #expect(live.events[chosen.id]?.first?.projectId == chosen.name)
        #expect(live.count(for: chosen) == 1 && live.archived[chosen.id] == nil)
        #expect(prior.projectId == original.name && session.eventSnapshot?.projectId == original.name)
        #expect(session.notePath == "fixture/note.md")
        decisions.occurrences[prior.id]?.projectId = nil
        #expect(view().recordingProjectNames[session.id] == nil)
        #expect(view().archived.isEmpty && view(agenda: [prior]).events.isEmpty)
        session.eventSnapshot = nil
        decisions.occurrences[prior.id]?.projectId = "Previous name"
        #expect(view().recordingProjectNames[session.id] == chosen.name)
        #expect(view().archived[chosen.id]?.first?.id == session.id)
    }

    @Test func confirmRechecksDatabaseAndSkipsProviderBackedRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aliases = AliasStore(fileURL: directory.appendingPathComponent("aliases.json"), seed: [])
        let project = try aliases.createProject(named: "Synthetic space")
        let database = try AppDatabase(inMemory: true)
        let store = ProjectAssignmentStore(database: database, aliasStore: aliases, didAssign: { Issue.record("Unexpected project summary refresh") })
        var draft = event("standalone", at: 500, series: nil)
        draft.title = project.name
        let target = draft
        try await database.dbQueue.write { db in try target.insert(db) }
        let suggestion = try #require(LocalProjectSuggestion.evaluate(target, history: [], decisions: .init(), projects: aliases.projects, now: Date()))
        await #expect(throws: ProjectAssignmentError.self) {
            try await store.confirm(suggestion, for: target, rememberFuture: true, classificationProjects: aliases.projects)
        }
        let rolledBack = try await database.dbQueue.read { try EventProjectAssignment.fetchCount($0) }
        #expect(rolledBack == 0)
        try await store.confirm(suggestion, for: target, rememberFuture: false, classificationProjects: aliases.projects)
        let decision = try await database.dbQueue.read { try LocalProjectDecisions.read($0).decision(for: target) }
        #expect(decision == .assigned(project.id))
        try await database.dbQueue.write { db in
            try EventProjectAssignment(dedupKey: target.id, projectId: nil, updatedAt: Date()).save(db)
        }
        await #expect(throws: ProjectAssignmentError.self) {
            try await store.confirm(suggestion, for: target, rememberFuture: false, classificationProjects: aliases.projects)
        }
        let latest = try await database.dbQueue.read { try LocalProjectDecisions.read($0).decision(for: target) }
        #expect(latest == .assigned(nil))
    }

    @Test func domainMatchesRequireAnExactDNSLabel() {
        let project = Project(id: "d", name: "Domain project", aliases: [ProjectAlias("team.example", .domain)])
        func score(_ email: String) -> Double {
            RulesEngine.score(.init(title: "Meeting", attendeeEmails: [email]), projects: [project]).first?.value ?? 0
        }
        #expect(score("person@sub.team.example") >= RulesEngine.inboxThreshold)
        #expect(score("person@team.example") >= RulesEngine.inboxThreshold)
        #expect(score("person@otherteam.example") == 0)
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
