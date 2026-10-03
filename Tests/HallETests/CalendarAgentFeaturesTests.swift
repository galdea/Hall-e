import Foundation
import Testing
import GRDB
@testable import HallE

private func testCalendarEvent(_ draft: CalendarEventDraft, account: String = "test@example.invalid", calendar: String = "fixture") throws -> CalendarEvent {
    var payload = try JSONSerialization.jsonObject(with: draft.googlePayload()) as! [String: Any]
    payload["iCalUID"] = draft.providerID + "@fixture"; payload["status"] = "confirmed"
    let event = try JSONDecoder().decode(GEvent.self, from: JSONSerialization.data(withJSONObject: payload))
    return EventMapper.map(event, accountEmail: account, calendarId: calendar, fetchedAt: Date())!
}

private actor CalendarWriterProbe: CalendarEventWriting {
    nonisolated var supportsIdempotentRetry: Bool { true }
    var attempts = 0
    let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func create(_ draft: CalendarEventDraft, in target: CalendarWriteTarget) async throws -> CalendarEvent {
        attempts += 1
        if failFirst && attempts == 1 { throw URLError(.timedOut) }
        await Task.yield()
        return try testCalendarEvent(draft, account: target.accountEmail, calendar: target.calendarID)
    }
}

private actor CalendarTransportProbe {
    var codes: [Int]
    var requests: [URLRequest] = []
    var invalidations = 0
    var body: Data
    init(codes: [Int], body: Data) { self.codes = codes; self.body = body }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let code = codes.removeFirst()
        return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
    func invalidate() { invalidations += 1 }
}

struct CalendarAgentFeaturesTests {
    private var zone: TimeZone { TimeZone(identifier: "America/Santiago")! }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    private func date(_ day: Int, hour: Int = 9) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
    private func draft() -> CalendarEventDraft { .init(title: "Project review", start: date(5), end: date(5, hour: 10), timeZoneID: zone.identifier) }
    private func target(mac: Bool = false) -> CalendarWriteTarget {
        CalendarWriteTarget(CalendarSource(accountEmail: mac ? "macos-calendars" : "test@example.invalid", calendarId: "fixture/path@example.invalid", summary: "Fixture", colorHex: nil, isPrimary: true, accessRole: "owner", isSelected: true))
    }
    private func database(target: CalendarWriteTarget) throws -> AppDatabase {
        let db = try AppDatabase(inMemory: true)
        try db.dbQueue.write {
            try ConnectedAccount(email: target.accountEmail, displayName: nil, colorHex: "#123456", addedAt: Date(), needsReauth: false, lastSyncAt: nil, lastSyncError: nil).insert($0)
            try CalendarSource(accountEmail: target.accountEmail, calendarId: target.calendarID, summary: target.name, colorHex: nil, isPrimary: true, accessRole: target.accessRole, isSelected: target.isSelected).insert($0)
        }
        return db
    }

    @Test func gridStartsMondayAndAlwaysContains42ConsecutiveDays() {
        let days = CalendarPresentation.days(in: date(5), calendar: calendar)
        #expect(days.count == 42)
        #expect(calendar.component(.weekday, from: days[0]) == 2)
        #expect(days[0] == calendar.date(from: DateComponents(year: 2026, month: 9, day: 28)))
        #expect(days.last == calendar.date(from: DateComponents(year: 2026, month: 11, day: 8)))
    }
    @Test func recurringAppearanceRequiresActualDailyOrWeeklyRule() {
        #expect(CalendarPresentation.routine("[\"RRULE:FREQ=WEEKLY;BYDAY=MO,WE\"]"))
        #expect(CalendarPresentation.routine("[\"RRULE:FREQ=DAILY\"]"))
        #expect(!CalendarPresentation.routine("[\"RRULE:FREQ=MONTHLY\"]"))
        #expect(!CalendarPresentation.routine(nil))
        #expect(!CalendarPresentation.routine("[\"My weekly class\"]"))
    }
    @Test func allDayEndIsExclusiveAndMultipleDaysRemainVisible() throws {
        var draft = draft(); draft.allDay = true; draft.start = date(5, hour: 0); draft.end = date(8, hour: 0)
        let event = EventDeduplicator.deduplicate([try testCalendarEvent(draft)], primaryEmail: nil) { _, _ in nil }[0]
        #expect(CalendarPresentation.events(on: date(5), events: [event], calendar: calendar).count == 1)
        #expect(CalendarPresentation.events(on: date(7), events: [event], calendar: calendar).count == 1)
        #expect(CalendarPresentation.events(on: date(8), events: [event], calendar: calendar).isEmpty)
    }
    @Test func cancelledAndDeclinedOccurrencesAreNeverManufactured() throws {
        var event = EventDeduplicator.deduplicate([try testCalendarEvent(draft())], primaryEmail: nil) { _, _ in nil }[0]
        event.recurrenceRulesJSON = "[\"RRULE:FREQ=DAILY\"]"
        #expect(CalendarPresentation.events(on: date(7), events: [event], calendar: calendar).isEmpty)
        #expect(CalendarPresentation.events(on: date(12), events: [event], calendar: calendar).isEmpty)
        event.status = "cancelled"
        #expect(CalendarPresentation.events(on: date(5), events: [event], calendar: calendar).isEmpty)
        event.status = "confirmed"; event.effectiveResponse = "declined"
        #expect(CalendarPresentation.events(on: date(5), events: [event], calendar: calendar).isEmpty)
    }
    @Test func draftValidatesTitleDurationTimeZoneAndProducesStableProviderID() throws {
        var invalid = draft(); invalid.title = "  "
        #expect(throws: CalendarCreationError.self) { try invalid.validated() }
        invalid = draft(); invalid.end = invalid.start
        #expect(throws: CalendarCreationError.self) { try invalid.validated() }
        invalid = draft(); invalid.timeZoneID = "not-a-zone"
        #expect(throws: CalendarCreationError.self) { try invalid.validated() }
        var valid = draft(); valid.repetition = .weekly
        let payload = try JSONSerialization.jsonObject(with: valid.googlePayload()) as! [String: Any]
        #expect(payload["id"] as? String == valid.providerID)
        #expect(valid.providerID.count == 32)
        #expect(payload["recurrence"] as? [String] == ["RRULE:FREQ=WEEKLY"])
        #expect((payload["start"] as? [String: String])?["timeZone"] == "America/Santiago")
        #expect(payload["attendees"] == nil)
    }
    @Test func rescheduledOccurrenceKeepsOriginalDedupIdentityAndMetadata() throws {
        var raw = try testCalendarEvent(draft()); raw.originalStartTs = raw.startTs
        raw.recurrenceRulesJSON = "[\"RRULE:FREQ=WEEKLY\"]"; raw.recurringEventId = "parent"
        let original = EventDeduplicator.dedupKey(for: raw)
        raw.startTs = date(7); raw.endTs = date(7, hour: 10); raw.recurrenceException = true
        #expect(EventDeduplicator.dedupKey(for: raw) == original)
        let mapped = EventDeduplicator.deduplicate([raw], primaryEmail: nil) { _, _ in nil }[0]
        #expect(mapped.recurrenceException == true)
        #expect(mapped.originalStartTs == date(5))
        #expect(CalendarPresentation.routine(mapped.recurrenceRulesJSON))
    }
    @Test func doubleClickAndRestartReturnOnePersistedResult() async throws {
        let target = target(), db = try database(target: target), writer = CalendarWriterProbe(), draft = draft()
        let coordinator = CalendarCreationCoordinator(database: db.dbQueue, writer: writer)
        async let first = coordinator.save(draft, target: target)
        async let second = coordinator.save(draft, target: target)
        let values = try await [first, second]
        #expect(values[0].eventId == values[1].eventId)
        #expect(await writer.attempts == 1)
        let restarted = CalendarCreationCoordinator(database: db.dbQueue, writer: writer)
        _ = try await restarted.save(draft, target: target)
        #expect(await writer.attempts == 1)
        #expect(try await db.dbQueue.read { try CalendarEvent.fetchCount($0) } == 1)
    }
    @Test func uncertainGoogleRetryReusesIDButUncertainMacRetryIsBlocked() async throws {
        let target = target(), db = try database(target: target), writer = CalendarWriterProbe(failFirst: true), draft = draft()
        let coordinator = CalendarCreationCoordinator(database: db.dbQueue, writer: writer)
        await #expect(throws: URLError.self) { try await coordinator.save(draft, target: target) }
        _ = try await coordinator.save(draft, target: target)
        #expect(await writer.attempts == 2)
        let macTarget = self.target(mac: true), macDB = try database(target: macTarget), macWriter = CalendarWriterProbe(failFirst: true)
        let mac = CalendarCreationCoordinator(database: macDB.dbQueue, writer: macWriter)
        await #expect(throws: URLError.self) { try await mac.save(draft, target: macTarget) }
        await #expect(throws: CalendarCreationError.self) { try await mac.save(draft, target: macTarget) }
        #expect(await macWriter.attempts == 1)
    }
    @Test func changedRequestAndReadOnlyCalendarAreRejectedBeforeProviderCall() async throws {
        var target = target(); let db = try database(target: target), writer = CalendarWriterProbe(), coordinator = CalendarCreationCoordinator(database: db.dbQueue, writer: writer)
        var draft = draft(); _ = try await coordinator.save(draft, target: target)
        draft.title = "Changed"
        await #expect(throws: CalendarCreationError.self) { try await coordinator.save(draft, target: target) }
        target.accessRole = "reader"; draft.requestID = UUID()
        await #expect(throws: CalendarCreationError.self) { try await coordinator.save(draft, target: target) }
        #expect(await writer.attempts == 1)
    }
    @Test func hiddenCalendarSaveDoesNotChangeSelectionOrAgendaCache() async throws {
        var target = target(); target.isSelected = false
        let db = try database(target: target), writer = CalendarWriterProbe(), coordinator = CalendarCreationCoordinator(database: db.dbQueue, writer: writer)
        _ = try await coordinator.save(draft(), target: target)
        #expect(try await db.dbQueue.read { try CalendarEvent.fetchCount($0) } == 0)
        #expect(try await db.dbQueue.read { try CalendarCreationRecord.fetchCount($0) } == 1)
    }
    @Test func googleRefreshAndConflictReconciliationUseSameIDAndEscapedCalendarPath() async throws {
        let draft = draft(), raw = try JSONEncoder().encode(try JSONDecoder().decode(GEvent.self, from: draft.googlePayload()))
        let probe = CalendarTransportProbe(codes: [401, 409, 200], body: raw)
        let writer = GoogleCalendarWriter(accessToken: { "test-token" }, invalidateToken: { await probe.invalidate() }, transport: { try await probe.send($0) })
        let event = try await writer.create(draft, in: target())
        #expect(event.eventId == draft.providerID)
        let requests = await probe.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "GET"])
        #expect(requests[0].httpBody == requests[1].httpBody)
        #expect(requests[0].url!.absoluteString.contains("fixture%2Fpath%40example.invalid"))
        #expect(await probe.invalidations == 1)
    }
    @Test func googleConflictWithDifferentContentRemainsUncertain() async throws {
        var existing = draft(); existing.title = "Different title"
        let draft = draft(); existing.requestID = draft.requestID
        let probe = CalendarTransportProbe(codes: [409, 200], body: try existing.googlePayload())
        let writer = GoogleCalendarWriter(accessToken: { "test-token" }, invalidateToken: {}, transport: { try await probe.send($0) })
        await #expect(throws: CalendarCreationError.self) { try await writer.create(draft, in: target()) }
    }
    @Test func oldEventSnapshotStillDecodesWithoutNewOptionalFields() throws {
        let original = EventDeduplicator.deduplicate([try testCalendarEvent(draft())], primaryEmail: nil) { _, _ in nil }[0]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for key in ["recurrenceRulesJSON", "recurringEventId", "recurrenceException", "originalStartTs"] { json[key] = nil }
        let decoded = try JSONDecoder().decode(UnifiedEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.dedupKey == original.dedupKey)
        #expect(decoded.recurrenceRulesJSON == nil)
    }
    @Test func sharedParticipantsCannotFileUnrelatedProjectsAndDomainsRequireBoundary() {
        let projects = [Project(id: "a", name: "A", aliases: [.init("shared@example.invalid", .email), .init("example.invalid", .domain)]),
                        Project(id: "b", name: "B", aliases: [.init("shared@example.invalid", .email), .init("example.invalid", .domain)])]
        let scores = RulesEngine.score(.init(title: "Review", attendeeEmails: ["shared@example.invalid"]), projects: projects)
        #expect(scores.allSatisfy { $0.value < RulesEngine.autoFileThreshold })
        let domain = Project(id: "x", name: "X", aliases: [.init("example.invalid", .domain)])
        #expect(RulesEngine.score(.init(title: "Review", attendeeEmails: ["person@notexample.invalid"]), projects: [domain])[0].value == 0)
        #expect(RulesEngine.score(.init(title: "Review", attendeeEmails: ["person@sub.example.invalid"]), projects: [domain])[0].value > 0)
    }
    @Test func oneExplicitProjectTitleOutweighsUnrelatedSharedParticipants() {
        let projects = [Project(id: "project-alpha", name: "ProjectAlpha", aliases: [.init("ProjectAlpha", .projectName)]),
                        Project(id: "project-beta", name: "ProjectBeta", aliases: [.init("a@example.invalid", .email), .init("b@example.invalid", .email)])]
        let scores = RulesEngine.score(.init(title: "ProjectAlpha planning", attendeeEmails: ["a@example.invalid", "b@example.invalid"]), projects: projects)
        #expect(scores[0].project.id == "project-alpha")
        #expect(scores[0].value - scores[1].value >= RulesEngine.ambiguityGap)
        let ambiguous = RulesEngine.score(.init(title: "ProjectAlpha and ProjectBeta integration", attendeeEmails: ["a@example.invalid"]), projects: projects)
        #expect(ambiguous.count == 2)
    }
    @Test func prepPopupRequiresFreshActualMeetingAndHonorsSnoozeRescheduleCancellation() throws {
        var event = EventDeduplicator.deduplicate([try testCalendarEvent(draft())], primaryEmail: nil) { _, _ in nil }[0]
        event.meetingURL = "https://meet.google.com/fixture"
        let now = event.startTs.addingTimeInterval(-300)
        func candidate(_ event: UnifiedEvent, receipts: [PreparationReceipt] = [], sync: Date? = nil, quiet: Bool = false) -> UnifiedEvent? {
            MeetingPreparationPolicy.candidate(events: [event], now: now, lastSync: sync ?? now, receipts: receipts, enabled: true, quiet: quiet)
        }
        #expect(candidate(event)?.dedupKey == event.dedupKey)
        #expect(candidate(event, sync: now.addingTimeInterval(-901)) == nil)
        #expect(candidate(event, quiet: true) == nil)
        let receipt = PreparationReceipt(occurrenceKey: MeetingPreparationPolicy.key(event), snoozedUntil: nil, expiresAt: event.endTs)
        #expect(candidate(event, receipts: [receipt]) == nil)
        var snoozed = receipt; snoozed.snoozedUntil = now.addingTimeInterval(60)
        #expect(candidate(event, receipts: [snoozed]) == nil)
        snoozed.snoozedUntil = now.addingTimeInterval(-1)
        #expect(candidate(event, receipts: [snoozed]) != nil)
        event.startTs = event.startTs.addingTimeInterval(-60)
        #expect(candidate(event, receipts: [receipt]) != nil)
        event.status = "cancelled"
        #expect(candidate(event) == nil)
    }
    @Test func weeklyCoverageExcludesUnauthorizedAndMarksStalePartialAndMissingSources() throws {
        let now = date(5), window = DateInterval(start: now, end: date(12))
        var source = WeeklyContextSource(id: "email", kind: .email, label: "Inbox", scope: "Authorized personal account", authorized: true,
            authorizationReference: "receipt-1", collectedAt: now, coveredFrom: now, coveredTo: window.end, completeScope: true,
            items: [.init(id: "message", title: "Email task", detail: "Do the task", occurredAt: now, citation: "mail:message")], error: nil)
        #expect(source.coverage(for: window, now: now) == .current)
        source.completeScope = false; #expect(source.coverage(for: window, now: now) == .partial)
        source.collectedAt = now.addingTimeInterval(-86401); #expect(source.coverage(for: window, now: now) == .stale)
        source.authorized = false; #expect(source.coverage(for: window, now: now) == .unauthorized)
        let text = WeeklyContextContract.markdown(sources: [source], interval: window, now: now)
        #expect(!text.contains("Email task"))
        #expect(text.contains("Not connected or imported."))
        #expect(text.contains("## Teaching") && text.contains("## Life"))
    }
}
