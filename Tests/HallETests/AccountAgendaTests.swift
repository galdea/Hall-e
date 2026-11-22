import Foundation
import Testing
@testable import HallE

private final class CalendarFixtureHTTP: URLProtocol {
    static var reply: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "calendar.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.reply!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let direct = request.httpBody { data = direct }
    else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&chunk, maxLength: chunk.count)
            if read <= 0 { break }
            buffer.append(chunk, count: read)
        }
        data = buffer
    } else { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

/// A signed-in model backed by the URLProtocol fake; nothing reaches the network or the Keychain.
@MainActor private struct SignedInFixture {
    let model: AccountAgendaModel
    let root: URL
    let suite: String
    let prefs: UserDefaults
    let vault: () -> String?
    let origin: URL

    static func make(openURL: @escaping (URL) -> Bool = { _ in true }) throws -> SignedInFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "test.halle.account.fixture." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarFixtureHTTP.self]
        final class Box { var value: String? }
        let box = Box()
        let model = AccountAgendaModel(preferences: prefs, cacheRoot: { root }, loadVault: { box.value },
                                       saveVault: { box.value = $0 }, transport: URLSession(configuration: config),
                                       openURL: openURL, packagedOrigin: nil)
        let origin = try AccountAPI.origin("https://calendar.example.invalid")
        model.endpoint = origin.absoluteString
        return .init(model: model, root: root, suite: suite, prefs: prefs, vault: { box.value }, origin: origin)
    }

    func signIn() async {
        model.email = "a@example.invalid"
        await model.run { try await model.startEmail() }
        model.code = "12345678"
        await model.run { try await model.finishEmail() }
    }

    func revocationCount() throws -> Int {
        guard let stored = vault() else { return 0 }
        let object = try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any]
        return (object?["revocations"] as? [Any])?.count ?? 0
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        prefs.removePersistentDomain(forName: suite)
        CalendarFixtureHTTP.reply = nil
    }
}

@Suite("Private account agenda", .serialized)
struct AccountAgendaTests {
    @Test func verifiedArchivedOccurrencesAreOfferedOnce() throws {
        let start = Date(timeIntervalSince1970: 1000)
        func recorded(_ id: String) -> RecordingSession {
            let event = UnifiedEvent(dedupKey: id, title: "Past review", startTs: start, endTs: start.addingTimeInterval(120),
                                     isAllDay: false, status: "confirmed", winnerAccountEmail: "host@example.invalid", sourcesJSON: "[]")
            var session = RecordingSession(event: event, notePath: nil)
            session.state = .completed
            return session
        }
        let current = recorded("current"), historical = recorded("earlier")
        var cancelled = try #require(current.eventSnapshot)
        cancelled.status = "cancelled"
        var missing = recorded("missing")
        missing.eventSnapshot = nil
        var mismatch = recorded("mismatch")
        mismatch.eventSnapshot = current.eventSnapshot
        var unfinished = recorded("unfinished")
        unfinished.state = .recording
        var newRetry = recorded("earlier")
        newRetry.startedAt = historical.startedAt.addingTimeInterval(1)
        newRetry.eventSnapshot?.title = "Retry in progress"
        newRetry.state = .recording
        var retryWithoutSnapshot = recorded("earlier")
        retryWithoutSnapshot.startedAt = newRetry.startedAt.addingTimeInterval(1)
        retryWithoutSnapshot.eventSnapshot = nil

        let original = recorded("cancelled-after-recording")
        var changed = recorded("cancelled-after-recording")
        changed.startedAt = original.startedAt.addingTimeInterval(1)
        changed.eventSnapshot?.status = "cancelled"
        changed.state = .recording
        let sessions = [current, historical, missing, mismatch, unfinished, newRetry, retryWithoutSnapshot, original, changed]
        let recordingIndex = RecordingStore.EventIndex(sessions)
        #expect(recordingIndex.latest["earlier"]?.id == retryWithoutSnapshot.id)
        #expect(recordingIndex.withSnapshot["earlier"]?.id == newRetry.id)
        #expect(recordingIndex.finishedWithSnapshot["earlier"]?.id == historical.id)
        let offered = AccountMeeting.recordedOccurrences(outside: [cancelled], recordings: recordingIndex.finishedWithSnapshot)
        #expect(offered.map(\.id) == ["earlier"])
        #expect(offered.first?.title == historical.eventSnapshot?.title)
    }

    @Test func copyConfirmedLocalProjectOnlyWhenSelected() throws {
        let origin = try AccountAPI.origin("https://calendar.example.invalid")
        func account(_ id: String) -> AccountConnection {
            .init(origin: origin, credentials: .init(userId: id, token: "test", expiresAt: 4_102_444_800_000))
        }
        let owner = account("A")
        let now = Date(timeIntervalSince1970: 1_000)
        let local = Project(id: "synthetic-local", name: "Prototype", aliases: [.init("Former name", .projectName)])
        let event = UnifiedEvent(dedupKey: "occurrence", title: "Design review", startTs: now, endTs: now.addingTimeInterval(60),
                                 isAllDay: false, status: "confirmed", iCalUID: "series", winnerAccountEmail: "host@example.invalid",
                                 projectId: "Inferred label", sourcesJSON: "[]")
        var decisions = LocalProjectDecisions()
        func candidate(_ who: AccountConnection, projects: [Project] = [local], existing: [AccountProject] = []) -> AccountProject? {
            AccountProject.confirmedCopy(for: event, decisions: decisions, projects: projects, account: who, existing: existing)
        }
        #expect(candidate(owner) == nil)
        decisions.recurring = [.init(seriesId: "series", effectiveFrom: now, projectId: local.id, updatedAt: now)]
        let project = try #require(candidate(owner))
        #expect(project.name == local.name && UUID(uuidString: project.id) != nil)
        #expect(candidate(account("B"))?.id != project.id)
        var renamed = local
        renamed.name = "Renamed prototype"
        #expect(candidate(owner, projects: [renamed])?.id == project.id)
        #expect(candidate(owner, projects: [renamed], existing: [project]) == project)
        decisions.occurrences[event.id] = .init(dedupKey: event.id, projectId: nil, updatedAt: now)
        #expect(candidate(owner) == nil)
        decisions.occurrences[event.id]?.projectId = "Former name"
        #expect(candidate(owner) == project)
        var archived = local
        archived.isArchived = true
        #expect(candidate(owner, projects: [archived]) == nil)
        let other = Project(id: "other", name: "Former name", aliases: [])
        #expect(candidate(owner, projects: [local, other]) == nil)

        var cache = AccountCalendarCache()
        #expect(try cache.importOccurrence(event, project: nil, into: owner))
        let first = try #require(cache.pending.first)
        #expect(first.body["project"] == nil)
        #expect(throws: AccountAgendaError.self) { try cache.importOccurrence(event, project: project, into: owner) }
        #expect(cache.pending.first?.mutationId == first.mutationId)
        var fromPhone = first.meeting
        fromPhone.title = "Updated on the phone"
        fromPhone.revision = 2
        cache.acknowledge(first, result: fromPhone)
        #expect(try cache.importOccurrence(event, project: project, into: owner))
        let withProject = try #require(cache.pending.first)
        #expect(withProject.meeting.id == first.meeting.id && withProject.meeting.title == fromPhone.title)
        #expect(withProject.body["project"] as? [String: String] == ["id": project.id, "name": project.name])
        var remote = withProject.meeting
        remote.revision = 3
        cache.acknowledge(withProject, result: remote)
        #expect(try !cache.importOccurrence(event, project: project, into: owner))
        cache.meetings[0].project = .init(id: UUID().uuidString, name: "Separate mobile choice")
        #expect(try !cache.importOccurrence(event, project: project, into: owner))
        cache.meetings[0].project = nil
        cache.meetings[0].deleted = true
        #expect(try !cache.importOccurrence(event, project: project, into: owner))
        #expect(cache.pending.isEmpty)
    }

    @Test func privateProjectIntentsPreserveOfflineAndLegacyEdits() throws {
        var cache = AccountCalendarCache()
        let project = AccountProject(id: UUID().uuidString.lowercased(), name: "Synthetic project")
        var meeting = AccountMeeting.draft(title: "Synthetic design review")
        meeting.project = project
        try cache.enqueue(meeting)
        var op = try #require(cache.pending.first)
        #expect((op.body["project"] as? [String: String])?["id"] == project.id)
        meeting.revision = 1
        cache.acknowledge(op, result: meeting)
        meeting.title = "Revised time"
        try cache.enqueue(meeting)
        op = try #require(cache.pending.first)
        #expect(op.body["project"] == nil)
        meeting.revision = 2
        cache.acknowledge(op, result: meeting)
        meeting.project = nil
        try cache.enqueue(meeting)
        let reopened = try JSONDecoder().decode(AccountCalendarCache.self, from: JSONEncoder().encode(cache))
        #expect(reopened.pending.first?.body["project"] is NSNull)
    }
    @Test func importsKeepTheSameOccurrenceAndPartitionsArePrivate() throws {
        let first = try AccountAPI.origin("https://Calendar.example.invalid:443/account/v1/")
        let same = try AccountAPI.origin("https://calendar.example.invalid")
        let second = try AccountAPI.origin("https://other.example.invalid")
        let id = AccountCalendarCache.importID(source: "fixture-occurrence", origin: first, userId: "A")
        #expect(UUID(uuidString: id) != nil)
        #expect(id == AccountCalendarCache.importID(source: "fixture-occurrence", origin: same, userId: "A"))
        #expect(id != AccountCalendarCache.importID(source: "fixture-occurrence", origin: second, userId: "A"))
        #expect(id != AccountCalendarCache.importID(source: "fixture-occurrence", origin: first, userId: "B"))
        #expect(id != AccountCalendarCache.importID(source: "second-occurrence", origin: first, userId: "A"))
        #expect(AccountCalendarCache.partition(first, "A") != AccountCalendarCache.partition(second, "A"))
        #expect(AccountCalendarCache.partition(first, "A") != AccountCalendarCache.partition(first, "B"))
        for bad in ["http://calendar.example.invalid", "https://calendar.example.invalid#token", "https://name@calendar.example.invalid",
                    "https://calendar.example.invalid?key=fixture", "https://calendar.example.invalid/custom"] {
            #expect(throws: AccountAgendaError.self) { try AccountAPI.origin(bad) }
        }
        #expect(AccountMeeting.date("2026-11-20T13:00:00Z") == AccountMeeting.date("2026-11-20T10:00:00.000-03:00"))
    }

    @Test func handleConflictAndShowOccurrenceAcrossLocalMidnight() throws {
        let start = try #require(AccountMeeting.date("2026-11-21T02:30:00Z"))
        let end = try #require(AccountMeeting.date("2026-11-21T03:30:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: -3 * 3600))
        var original = AccountMeeting.draft(title: "Synthetic", start: start, end: end)
        #expect(original.occurs(on: start, calendar: calendar))
        #expect(original.occurs(on: end, calendar: calendar))
        #expect(!original.occurs(on: start.addingTimeInterval(-86400), calendar: calendar))
        original.revision = 2
        var cache = AccountCalendarCache(meetings: [original])
        var stale = original
        stale.revision = 1
        stale.title = "Pending local title"
        try cache.enqueue(stale)
        cache.pending[0].conflict = true
        let conflict = cache.pending[0]
        #expect(cache.visible.first?.title == original.title)
        try cache.reapply(conflict)
        #expect(cache.pending.first?.meeting.revision == 2)
        #expect(cache.pending.first?.mutationId != conflict.mutationId)
        #expect(cache.visible.first?.title == stale.title)
        cache.pending[0].conflict = true
        cache.meetings[0].deleted = true
        let tombstoneConflict = cache.pending[0]
        #expect(throws: AccountAgendaError.self) { try cache.reapply(tombstoneConflict) }
        #expect(cache.visible.isEmpty)
        var invalid = original
        invalid.endAt = invalid.startAt
        var empty = AccountCalendarCache()
        #expect(throws: AccountAgendaError.self) { try empty.enqueue(invalid) }
    }

    @MainActor @Test func replayAfterLostResponseAndUserSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "test.halle.account." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            prefs.removePersistentDomain(forName: suite)
            CalendarFixtureHTTP.reply = nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarFixtureHTTP.self]
        let transport = URLSession(configuration: config)
        var fakeVault: String?
        func device(packagedOrigin: String? = "https://Packaged.example.invalid:443/account/v1/") -> AccountAgendaModel {
            AccountAgendaModel(preferences: prefs, cacheRoot: { root }, loadVault: { fakeVault },
                               saveVault: { fakeVault = $0 }, transport: transport, packagedOrigin: packagedOrigin)
        }
        let origin = try AccountAPI.origin("https://calendar.example.invalid")
        let credentialsA = AccountCredentials(userId: "test-A", token: "fixture-A", expiresAt: 4_102_444_800_000)
        let credentialsB = AccountCredentials(userId: "test-B", token: "fixture-B", expiresAt: 4_102_444_800_000)
        var login = credentialsA
        var isOffline = false
        var revoked = false
        var puts: [String] = []
        var unchangedCount = 0
        let stableVersion = String(repeating: "a", count: 32)
        var serverMeeting: AccountMeeting?
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        let draft = AccountMeeting.draft(title: "Synthetic A")
        CalendarFixtureHTTP.reply = { req in
            if isOffline { throw URLError(.notConnectedToInternet) }
            let path = req.url!.path
            let token = req.value(forHTTPHeaderField: "Authorization")
            if path.hasSuffix("/auth/email/start") { return (200, try json(["challengeId": "fixture-challenge"])) }
            if path.hasSuffix("/auth/email/verify") { return (200, try JSONEncoder().encode(login)) }
            if path.hasSuffix("/auth/logout") { return (204, Data()) }
            if revoked { return (401, try json(["error":"session_expired"])) }
            if req.httpMethod == "PUT", token == "Bearer fixture-A", path.hasSuffix("/" + draft.id) {
                let stream = req.httpBodyStream
                stream?.open()
                defer { stream?.close() }
                let object: Any
                if let direct = req.httpBody { object = try JSONSerialization.jsonObject(with: direct) }
                else if let stream { object = try JSONSerialization.jsonObject(with: stream) }
                else { throw AccountAgendaError.invalidResponse }
                let payload = try #require(object as? [String: Any])
                puts.append(try #require(payload["mutationId"] as? String))
                if serverMeeting == nil {
                    var accepted = draft
                    accepted.revision = 1
                    accepted.recordings = [.init(id: "fixture-recording", status: "completed", transcript: "Synthetic transcript")]
                    serverMeeting = accepted
                    isOffline = true
                    throw URLError(.networkConnectionLost)
                }
                return (200, try JSONEncoder().encode(["meeting":serverMeeting!]))
            }
            if path.hasSuffix("/meetings"), req.httpMethod == "GET" {
                let records: [AccountMeeting] = token == "Bearer fixture-A" ? [serverMeeting].compactMap { $0 } : []
                if serverMeeting != nil && token == "Bearer fixture-A" {
                    let cursor = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since" }?.value
                    if cursor == stableVersion {
                        unchangedCount += 1
                        return (200, try json(["version":stableVersion, "unchanged":true]))
                    }
                    struct Page: Encodable { var meetings: [AccountMeeting]; var version: String }
                    return (200, try JSONEncoder().encode(Page(meetings: records, version: stableVersion)))
                }
                return (200, try JSONEncoder().encode(["meetings":records]))
            }
            return (404, Data())
        }
        func signIn(_ client: AccountAgendaModel, email: String) async {
            client.endpoint = origin.absoluteString
            client.email = email
            await client.run { try await client.startEmail() }
            client.code = "12345678"
            await client.run { try await client.finishEmail() }
        }
        #expect(device(packagedOrigin: nil).endpoint.isEmpty)
        #expect(device(packagedOrigin: "http://invalid.example.invalid").endpoint.isEmpty)
        let first = device()
        #expect(first.endpoint == "https://packaged.example.invalid")
        await signIn(first, email: "a@example.invalid")
        #expect(first.account?.credentials == credentialsA)
        try first.enqueue(draft)
        await first.run { try await first.synchronize() }
        #expect(first.cache.pending.count == 1)
        #expect(puts.count == 1)
        let queuedID = try #require(first.cache.pending.first?.id)
        let restarted = device()
        await restarted.run {}
        #expect(restarted.cache.pending.first?.id == queuedID)
        isOffline = false
        await restarted.run { try await restarted.synchronize() }
        #expect(puts == [queuedID, queuedID])
        #expect(restarted.cache.pending.isEmpty)
        #expect(restarted.cache.visible.first?.recordings.first?.transcript == "Synthetic transcript")

        #expect(restarted.cache.version == stableVersion)
        await restarted.run { try await restarted.synchronize() }
        #expect(unchangedCount == 1)
        #expect(restarted.cache.visible.first?.recordings.first?.transcript == "Synthetic transcript")
        await restarted.run { try await restarted.synchronize(force: true) }
        #expect(unchangedCount == 1)
        isOffline = true
        await restarted.run { try await restarted.signOut() }
        #expect(restarted.account == nil && restarted.cache.visible.isEmpty)
        #expect(device().endpoint == origin.absoluteString)
        isOffline = false
        login = credentialsB
        await signIn(restarted, email: "b@example.invalid")
        #expect(restarted.account?.credentials == credentialsB)
        #expect(restarted.cache.visible.isEmpty && restarted.cache.pending.isEmpty)
        let savedA = try AccountCalendarCache.load(from: AccountCalendarCache.file(in: root, origin: origin, userId: credentialsA.userId))
        #expect(savedA.visible.first?.id == draft.id)
        revoked = true
        await restarted.run { try await restarted.synchronize() }
        #expect(restarted.account == nil && restarted.cache.visible.isEmpty)
    }

    @MainActor @Test func permanent4xxParksConflictWithoutBlockingSyncAndRunSerializesUserActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "test.halle.account.resilience." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            prefs.removePersistentDomain(forName: suite)
            CalendarFixtureHTTP.reply = nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarFixtureHTTP.self]
        let transport = URLSession(configuration: config)
        var fakeVault: String?
        let model = AccountAgendaModel(preferences: prefs, cacheRoot: { root }, loadVault: { fakeVault },
                                       saveVault: { fakeVault = $0 }, transport: transport, openURL: { _ in true })
        let origin = try AccountAPI.origin("https://calendar.example.invalid")
        let credentials = AccountCredentials(userId: "test-A", token: "fixture-A", expiresAt: 4_102_444_800_000)
        let badDraft = AccountMeeting.draft(title: "Rejected by server")
        let goodDraft = AccountMeeting.draft(title: "Accepted by server")
        var serverMeetings: [AccountMeeting] = []
        var importedCalls: [String] = []
        var googleFinishStatus = 401
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        CalendarFixtureHTTP.reply = { req in
            let path = req.url!.path
            if path.hasSuffix("/auth/email/start") { return (200, try json(["challengeId": "c1"])) }
            if path.hasSuffix("/auth/email/verify") { return (200, try JSONEncoder().encode(credentials)) }
            if path.hasSuffix("/auth/browser/start") {
                return (200, try json(["url": "https://accounts.google.com/o/oauth2/v2/auth?state=s", "pollToken": "poll-1"]))
            }
            if path.hasSuffix("/auth/browser/finish") {
                return (googleFinishStatus, try json(["error": googleFinishStatus == 401 ? "invalid_confirmation" : "attempt_expired"]))
            }
            if req.httpMethod == "PUT", path.hasSuffix("/" + badDraft.id) {
                return (400, try json(["error": "invalid_meeting"]))
            }
            if req.httpMethod == "PUT", path.hasSuffix("/" + goodDraft.id) {
                var saved = goodDraft
                saved.revision = 1
                serverMeetings = [saved]
                return (200, try JSONEncoder().encode(["meeting": saved]))
            }
            if path.contains("/imports/") {
                importedCalls.append("\(req.httpMethod ?? "") \(path)")
                if req.httpMethod == "PUT" {
                    return (200, try json(["recording": ["id": "imp", "status": "completed", "transcript": "hi", "source": "local-import"]]))
                }
                if req.httpMethod == "DELETE" { return (204, Data()) }
            }
            if path.hasSuffix("/meetings"), req.httpMethod == "GET" {
                return (200, try JSONEncoder().encode(["meetings": serverMeetings]))
            }
            return (404, Data())
        }

        // Terminal Google browser errors clear browserToken; 401 keeps it for retry.
        model.endpoint = origin.absoluteString
        await model.run { try await model.google() }
        #expect(model.waitingForBrowser)
        model.confirmationCode = "12345678"
        googleFinishStatus = 401
        await model.run { try await model.finishGoogle() }
        #expect(model.waitingForBrowser)
        googleFinishStatus = 410
        await model.run { try await model.finishGoogle() }
        #expect(!model.waitingForBrowser)

        // Sign in and verify permanent 400 parks as conflict without blocking goodDraft or GET /meetings.
        model.email = "a@example.invalid"
        await model.run { try await model.startEmail() }
        model.code = "12345678"
        await model.run { try await model.finishEmail() }
        try model.enqueue(badDraft)
        try model.enqueue(goodDraft)
        await model.run { try await model.synchronize() }
        #expect(model.cache.pending.count == 1)
        #expect(model.cache.pending.first?.meeting.id == badDraft.id)
        #expect(model.cache.pending.first?.conflict == true)
        #expect(model.cache.visible.contains { $0.id == goodDraft.id && $0.revision == 1 })

        // Transcript import uses injected transport and meeting-scoped import IDs.
        let account = try #require(model.account)
        let sessionId = UUID()
        let idA = AccountAgendaModel.transcriptImportID(meetingId: goodDraft.id, sessionId: sessionId, account: account)
        let idB = AccountAgendaModel.transcriptImportID(meetingId: badDraft.id, sessionId: sessionId, account: account)
        #expect(idA != idB)
        await model.run { try await model.importTranscript(meetingId: goodDraft.id, importId: idA, text: "Synthetic", into: account) }
        await model.run { try await model.removeImportedTranscript(meetingId: goodDraft.id, importId: idA, from: account) }
        #expect(importedCalls.count == 2)
        #expect(importedCalls[0].hasPrefix("PUT "))
        #expect(importedCalls[1].hasPrefix("DELETE "))

        // Concurrent user run serializes behind background run instead of dropping; extra background run skips.
        var order: [String] = []
        let bg = Task { @MainActor in
            await model.run(background: true) {
                order.append("bg-start")
                try await Task.sleep(for: .milliseconds(40))
                order.append("bg-end")
            }
        }
        await Task.yield()
        let bgDropped = Task { @MainActor in
            await model.run(background: true) { order.append("bg-dropped") }
        }
        let user = Task { @MainActor in
            await model.run { order.append("user") }
        }
        await bg.value
        await bgDropped.value
        await user.value
        #expect(order == ["bg-start", "bg-end", "user"])

        // Debug fixture mode isolates shared instance from real Keychain/defaults.
        let fixtureShared = AccountAgendaModel.makeShared(environment: ["HALLE_DEBUG_FIXTURES": "1"])
        await fixtureShared.run {}
        #expect(fixtureShared.account == nil)
    }

    @Test func conflictShowsServerCopyAndOnlySavesDeletedEditsAsNewMeetings() throws {
        let project = AccountProject(id: UUID().uuidString.lowercased(), name: "Synthetic project")
        var server = AccountMeeting.draft(title: "Server title")
        server.revision = 3
        server.project = project
        server.recordings = [.init(id: "rec", status: "completed", transcript: "Synthetic")]
        var stale = server
        stale.revision = 2
        stale.title = "Mac title"
        stale.endAt = AccountMeeting.timestamp(Date(timeIntervalSince1970: 9_000_000))
        stale.startAt = AccountMeeting.timestamp(Date(timeIntervalSince1970: 8_000_000))
        var cache = AccountCalendarCache(meetings: [server])
        try cache.enqueue(stale)
        cache.pending[0].conflict = true
        let edit = cache.pending[0]

        // Live server copy: show both versions, offer rebase, never "save as new".
        let live = cache.conflict(for: edit)
        #expect(live.server == .live(server))
        #expect(live.local.title == "Mac title")
        #expect(live.canReapply && !live.canSaveAsNew && !live.localDeletes)
        #expect(throws: AccountAgendaError.self) { try cache.saveAsNew(edit) }

        // Deleted on another device: the edit can become a fresh meeting.
        cache.meetings[0].deleted = true
        let tombstone = cache.conflict(for: edit)
        guard case .deleted(let gone) = tombstone.server else { Issue.record("expected tombstone"); return }
        #expect(gone.id == server.id)
        #expect(!tombstone.canReapply && tombstone.canSaveAsNew)
        let freshID = UUID().uuidString.lowercased()
        #expect(throws: AccountAgendaError.self) { try cache.saveAsNew(edit, id: server.id) }
        let copy = try cache.saveAsNew(edit, id: freshID)
        #expect(copy.id == freshID && copy.id != server.id)
        #expect(copy.revision == 0 && !copy.deleted && copy.recordings.isEmpty)
        #expect(copy.title == stale.title && copy.startAt == stale.startAt && copy.endAt == stale.endAt && copy.project == project)
        #expect(cache.pending.count == 1)
        let queued = try #require(cache.pending.first)
        #expect(!queued.conflict && queued.mutationId != edit.mutationId)
        #expect(queued.body["baseRevision"] as? Int == 0)
        #expect((queued.body["project"] as? [String: String])?["id"] == project.id)
        #expect(cache.meetings == [gone])
        #expect(cache.visible.map(\.id) == [freshID])
        #expect(throws: AccountAgendaError.self) { try cache.saveAsNew(edit) }

        // A pending delete must never be resurrected as a new meeting.
        var deleteCache = AccountCalendarCache(meetings: [server])
        var deletion = stale
        deletion.deleted = true
        try deleteCache.enqueue(deletion)
        deleteCache.pending[0].conflict = true
        deleteCache.meetings[0].deleted = true
        let deleteConflict = deleteCache.conflict(for: deleteCache.pending[0])
        #expect(deleteConflict.localDeletes && !deleteConflict.canSaveAsNew && !deleteConflict.canReapply)
        #expect(throws: AccountAgendaError.self) { try deleteCache.saveAsNew(deleteCache.pending[0]) }
        #expect(deleteCache.pending.count == 1 && deleteCache.pending[0].conflict)

        // A rejected new meeting has no server copy; it may be retried under a new ID or discarded.
        var rejectedCache = AccountCalendarCache()
        try rejectedCache.enqueue(.draft(title: "Rejected"))
        let unparked = rejectedCache.pending[0]
        #expect(throws: AccountAgendaError.self) { try rejectedCache.saveAsNew(unparked) }
        rejectedCache.pending[0].conflict = true
        let missing = rejectedCache.conflict(for: rejectedCache.pending[0])
        #expect(missing.server == .missing && missing.canSaveAsNew && !missing.canReapply)
    }

    @MainActor @Test func savingADeletedMeetingAsNewSyncsAFreshMeetingAtRevisionZero() async throws {
        let fixture = try SignedInFixture.make()
        defer { fixture.tearDown() }
        let model = fixture.model
        var original = AccountMeeting.draft(title: "Deleted on the phone")
        original.revision = 4
        var tombstone = original
        tombstone.deleted = true
        tombstone.revision = 5
        var serverMeetings = [original]
        var puts: [(id: String, body: [String: Any])] = []
        let credentials = AccountCredentials(userId: "test-A", token: "fixture-A", expiresAt: 4_102_444_800_000)
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        CalendarFixtureHTTP.reply = { req in
            let path = req.url!.path
            if path.hasSuffix("/auth/email/start") { return (200, try json(["challengeId": "c1"])) }
            if path.hasSuffix("/auth/email/verify") { return (200, try JSONEncoder().encode(credentials)) }
            if req.httpMethod == "PUT", path.contains("/meetings/") {
                let id = String(path.split(separator: "/").last!)
                let body = try requestJSON(req)
                puts.append((id, body))
                if id == original.id { return (409, try json(["error": "revision_conflict"])) }
                var saved = AccountMeeting.draft(id: id, title: body["title"] as? String ?? "")
                saved.startAt = body["startAt"] as? String ?? saved.startAt
                saved.endAt = body["endAt"] as? String ?? saved.endAt
                saved.revision = 1
                serverMeetings.append(saved)
                return (200, try JSONEncoder().encode(["meeting": saved]))
            }
            if path.hasSuffix("/meetings"), req.httpMethod == "GET" {
                return (200, try JSONEncoder().encode(["meetings": serverMeetings]))
            }
            return (404, Data())
        }
        await fixture.signIn()
        #expect(model.cache.visible.map(\.id) == [original.id])
        var edit = original
        edit.title = "Kept on the Mac"
        try model.enqueue(edit)
        serverMeetings = [tombstone]
        await model.run { try await model.synchronize() }
        let parked = try #require(model.cache.pending.first)
        #expect(parked.conflict)
        guard case .deleted = model.conflict(for: parked).server else { Issue.record("expected tombstone"); return }
        #expect(model.conflict(for: parked).local.title == "Kept on the Mac")

        try model.saveAsNewMeeting(parked)
        await model.run { try await model.synchronize() }
        let last = try #require(puts.last)
        #expect(last.id != original.id && UUID(uuidString: last.id) != nil)
        #expect(last.body["baseRevision"] as? Int == 0)
        #expect(last.body["title"] as? String == "Kept on the Mac")
        #expect(last.body["deleted"] as? Bool == false)
        #expect(last.body["mutationId"] as? String != parked.mutationId)
        #expect(model.cache.pending.isEmpty)
        #expect(model.cache.visible.map(\.title) == ["Kept on the Mac"])
    }

    @Test func transcriptImportPolicyEnforcesTheLimitAndRejectsBlankText() throws {
        let limit = AccountTranscriptImportPolicy.maxBytes
        #expect(limit == 512 * 1024)
        let exact = String(repeating: "a", count: limit)
        #expect(try AccountTranscriptImportPolicy.copy(plainText: "a", speakerLabeledText: exact) == exact)
        #expect(throws: TranscriptImportFailure.tooLarge) {
            try AccountTranscriptImportPolicy.copy(plainText: "a", speakerLabeledText: exact + "a")
        }
        // The limit is in UTF-8 bytes, not characters.
        let multibyte = String(repeating: "é", count: limit / 2 + 1)
        #expect(multibyte.count < limit)
        #expect(throws: TranscriptImportFailure.tooLarge) {
            try AccountTranscriptImportPolicy.copy(plainText: "é", speakerLabeledText: multibyte)
        }
        #expect(throws: TranscriptImportFailure.unavailable) {
            try AccountTranscriptImportPolicy.copy(plainText: " \n\t ", speakerLabeledText: "Speaker 1: ")
        }
        #expect(throws: TranscriptImportFailure.unavailable) {
            try AccountTranscriptImportPolicy.copy(plainText: "Hello", speakerLabeledText: "\n  ")
        }
        #expect(try AccountTranscriptImportPolicy.copy(plainText: "Hello", speakerLabeledText: "Speaker 1: Hello") == "Speaker 1: Hello")

        #expect(AccountTranscriptImportPolicy.message(for: AccountAgendaError.response(410, "import_removed")) != nil)
        #expect(AccountTranscriptImportPolicy.message(for: AccountAgendaError.response(409, "import_conflict")) != nil)
        #expect(AccountTranscriptImportPolicy.message(for: AccountAgendaError.response(410, "gone")) == nil)
        #expect(AccountTranscriptImportPolicy.message(for: AccountAgendaError.response(409, "revision_conflict")) == nil)
        #expect(AccountTranscriptImportPolicy.message(for: AccountAgendaError.response(500, "import_removed")) == nil)
        #expect(AccountTranscriptImportPolicy.message(for: URLError(.timedOut)) == nil)
    }

    @MainActor @Test func transcriptImportUsesInjectedTransportAndSurfacesRemovedAndConflictingCopies() async throws {
        let fixture = try SignedInFixture.make()
        defer { fixture.tearDown() }
        let model = fixture.model
        var meeting = AccountMeeting.draft(title: "Synthetic review")
        meeting.revision = 1
        var other = AccountMeeting.draft(title: "Other review")
        other.revision = 1
        let credentials = AccountCredentials(userId: "test-A", token: "fixture-A", expiresAt: 4_102_444_800_000)
        var importStatus = 200
        var importCode = ""
        var requests: [(method: String, path: String, auth: String?, body: [String: Any])] = []
        var gets = 0
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        CalendarFixtureHTTP.reply = { req in
            let path = req.url!.path
            if path.hasSuffix("/auth/email/start") { return (200, try json(["challengeId": "c1"])) }
            if path.hasSuffix("/auth/email/verify") { return (200, try JSONEncoder().encode(credentials)) }
            if path.contains("/imports/") {
                requests.append((req.httpMethod ?? "", path, req.value(forHTTPHeaderField: "Authorization"), try requestJSON(req)))
                if req.httpMethod == "DELETE" { return (204, Data()) }
                if importStatus != 200 { return (importStatus, try json(["error": importCode])) }
                return (200, try json(["recording": ["id": "imp", "status": "completed", "transcript": "hi", "source": "local-import"]]))
            }
            if path.hasSuffix("/meetings"), req.httpMethod == "GET" {
                gets += 1
                return (200, try JSONEncoder().encode(["meetings": [meeting, other]]))
            }
            return (404, Data())
        }
        await fixture.signIn()
        let account = try #require(model.account)
        let session = UUID()
        let importID = AccountAgendaModel.transcriptImportID(meetingId: meeting.id, sessionId: session, account: account)
        #expect(UUID(uuidString: importID) != nil)
        #expect(importID == AccountAgendaModel.transcriptImportID(meetingId: meeting.id, sessionId: session, account: account))
        #expect(importID != AccountAgendaModel.transcriptImportID(meetingId: other.id, sessionId: session, account: account))
        #expect(importID != AccountAgendaModel.transcriptImportID(meetingId: meeting.id, sessionId: UUID(), account: account))
        var otherUser = account
        otherUser.credentials.userId = "test-B"
        #expect(importID != AccountAgendaModel.transcriptImportID(meetingId: meeting.id, sessionId: session, account: otherUser))

        // Success: PUT through the injected transport with consent, then a forced sync.
        let getsBefore = gets
        try await model.importTranscript(meetingId: meeting.id, importId: importID, text: "Speaker 1: Hi", into: account)
        #expect(gets == getsBefore + 1)
        let put = try #require(requests.last)
        #expect(put.method == "PUT")
        #expect(put.path.hasSuffix("/account/v1/meetings/\(meeting.id)/imports/\(importID)"))
        #expect(put.auth == "Bearer fixture-A")
        #expect(put.body["consent"] as? Bool == true && put.body["transcript"] as? String == "Speaker 1: Hi")

        // 410 import_removed and 409 import_conflict are surfaced with their own copy and skip the sync.
        for (status, code) in [(410, "import_removed"), (409, "import_conflict")] {
            importStatus = status
            importCode = code
            let getsBeforeFailure = gets
            var caught: Error?
            do { try await model.importTranscript(meetingId: meeting.id, importId: importID, text: "x", into: account) }
            catch { caught = error }
            let failure = try #require(caught)
            guard case AccountAgendaError.response(status, code) = failure else { Issue.record("unexpected \(failure)"); continue }
            #expect(AccountTranscriptImportPolicy.message(for: failure) != nil)
            #expect(gets == getsBeforeFailure)
        }

        // Removal sends DELETE for the same meeting and import.
        importStatus = 200
        try await model.removeImportedTranscript(meetingId: meeting.id, importId: importID, from: account)
        let delete = try #require(requests.last)
        #expect(delete.method == "DELETE" && delete.path.hasSuffix("/meetings/\(meeting.id)/imports/\(importID)"))
        #expect(delete.auth == "Bearer fixture-A")

        // A different account than the active one is refused before any request.
        let count = requests.count
        await #expect(throws: AccountAgendaError.self) {
            try await model.importTranscript(meetingId: meeting.id, importId: importID, text: "x", into: otherUser)
        }
        await #expect(throws: AccountAgendaError.self) {
            try await model.removeImportedTranscript(meetingId: meeting.id, importId: importID, from: otherUser)
        }
        #expect(requests.count == count)
    }

    @MainActor @Test func googleSignInOpensOnlyTheExactAuthorizationEndpointAndClearsTerminalAttempts() async throws {
        var opened: [URL] = []
        var openResult = true
        let fixture = try SignedInFixture.make(openURL: { opened.append($0); return openResult })
        defer { fixture.tearDown() }
        let model = fixture.model
        var authURL = "https://accounts.google.com/o/oauth2/v2/auth?state=s"
        var finishStatus = 202
        var finishCalls = 0
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        CalendarFixtureHTTP.reply = { req in
            let path = req.url!.path
            if path.hasSuffix("/auth/browser/start") { return (200, try json(["url": authURL, "pollToken": "poll-1"])) }
            if path.hasSuffix("/auth/browser/finish") {
                finishCalls += 1
                return (finishStatus, try json(finishStatus == 202 ? ["status": "pending"] : ["error": "attempt_failed"]))
            }
            return (404, Data())
        }
        let rejected = [
            "http://accounts.google.com/o/oauth2/v2/auth",
            "https://accounts.google.com:443/o/oauth2/v2/auth",
            "https://accounts.google.com:8443/o/oauth2/v2/auth",
            "https://user@accounts.google.com/o/oauth2/v2/auth",
            "https://user:secret@accounts.google.com/o/oauth2/v2/auth",
            "https://accounts.google.com/o/oauth2/v2/auth/extra",
            "https://accounts.google.com/o/oauth2/auth",
            "https://accounts.google.com/",
            "https://accounts.google.com.example.invalid/o/oauth2/v2/auth",
            "https://example.invalid/o/oauth2/v2/auth",
        ]
        for candidate in rejected {
            authURL = candidate
            await model.run { try await model.google() }
            #expect(!model.waitingForBrowser, "accepted \(candidate)")
            #expect(model.message == AccountAgendaError.browser.localizedDescription)
        }
        #expect(opened.isEmpty)

        // The exact endpoint is opened once; a failed open does not leave a pending attempt.
        authURL = "https://accounts.google.com/o/oauth2/v2/auth?state=s"
        openResult = false
        await model.run { try await model.google() }
        #expect(!model.waitingForBrowser && opened.count == 1)
        openResult = true
        await model.run { try await model.google() }
        #expect(model.waitingForBrowser && opened.last == URL(string: authURL))

        // A malformed code is refused locally and keeps the attempt.
        model.confirmationCode = "1234567"
        await model.run { try await model.finishGoogle() }
        #expect(finishCalls == 0 && model.waitingForBrowser)

        // 202 keeps the attempt open; 403/409/410 end it.
        model.confirmationCode = "12345678"
        finishStatus = 202
        await model.run { try await model.finishGoogle() }
        #expect(finishCalls == 1 && model.waitingForBrowser && model.account == nil)
        for status in [403, 409, 410] {
            if !model.waitingForBrowser { await model.run { try await model.google() } }
            #expect(model.waitingForBrowser)
            model.confirmationCode = "12345678"
            finishStatus = status
            await model.run { try await model.finishGoogle() }
            #expect(!model.waitingForBrowser, "kept attempt after \(status)")
            #expect(model.confirmationCode.isEmpty)
        }
    }

    @MainActor @Test func signOutRevokesOnlineAndRetriesQueuedRevocations() async throws {
        let fixture = try SignedInFixture.make()
        defer { fixture.tearDown() }
        let model = fixture.model
        let credentials = AccountCredentials(userId: "test-A", token: "fixture-A", expiresAt: 4_102_444_800_000)
        var logoutStatus = 204
        var logouts: [String?] = []
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        CalendarFixtureHTTP.reply = { req in
            let path = req.url!.path
            if path.hasSuffix("/auth/email/start") { return (200, try json(["challengeId": "c1"])) }
            if path.hasSuffix("/auth/email/verify") { return (200, try JSONEncoder().encode(credentials)) }
            if path.hasSuffix("/auth/logout") {
                logouts.append(req.value(forHTTPHeaderField: "Authorization"))
                return (logoutStatus, logoutStatus == 204 ? Data() : try json(["error": "unavailable"]))
            }
            if path.hasSuffix("/meetings"), req.httpMethod == "GET" { return (200, try json(["meetings": []])) }
            return (404, Data())
        }

        // Online: the server session is revoked immediately and nothing stays queued.
        await fixture.signIn()
        #expect(model.account?.credentials == credentials)
        await model.run { try await model.signOut() }
        #expect(model.account == nil)
        #expect(logouts == ["Bearer fixture-A"])
        #expect(try fixture.revocationCount() == 0)
        #expect(model.message.isEmpty)

        // Server failure: signed out locally, revocation queued and retried on the next sync.
        await fixture.signIn()
        logoutStatus = 503
        await model.run { try await model.signOut() }
        #expect(model.account == nil)
        #expect(logouts.count == 2)
        #expect(try fixture.revocationCount() == 1)
        #expect(!model.message.isEmpty)
        logoutStatus = 204
        await model.run { try await model.synchronize() }
        #expect(logouts.count == 3 && logouts.last == "Bearer fixture-A")
        #expect(try fixture.revocationCount() == 0)

        // Already revoked (401) counts as done.
        await fixture.signIn()
        logoutStatus = 401
        await model.run { try await model.signOut() }
        #expect(logouts.count == 4)
        #expect(try fixture.revocationCount() == 0)
        #expect(model.message.isEmpty)
    }

    @MainActor @Test func discardRecordingSendsDeleteForReviewOrFailedRecordingsAndSurfacesActive() async throws {
        let fixture = try SignedInFixture.make()
        defer { fixture.tearDown() }
        let model = fixture.model
        let credentials = AccountCredentials(userId: "test-A", token: "fixture-A", expiresAt: 4_102_444_800_000)
        let review = AccountRecording(id: "rec-review", status: "review")
        let failed = AccountRecording(id: "rec-failed", status: "failed")
        var meeting = AccountMeeting.draft(title: "Oversize transcript")
        meeting.revision = 2
        meeting.recordings = [review, failed]
        var deleteStatus = 204
        var deletes: [(path: String, auth: String?)] = []
        var gets = 0
        func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        CalendarFixtureHTTP.reply = { req in
            let path = req.url!.path
            if path.hasSuffix("/auth/email/start") { return (200, try json(["challengeId": "c1"])) }
            if path.hasSuffix("/auth/email/verify") { return (200, try JSONEncoder().encode(credentials)) }
            if req.httpMethod == "DELETE", path.contains("/recordings/") {
                deletes.append((path, req.value(forHTTPHeaderField: "Authorization")))
                if deleteStatus == 204 {
                    meeting.recordings.removeAll { path.hasSuffix("/" + $0.id) }
                    return (204, Data())
                }
                return (deleteStatus, try json(["error": "recording_active"]))
            }
            if path.hasSuffix("/meetings"), req.httpMethod == "GET" {
                gets += 1
                return (200, try JSONEncoder().encode(["meetings": [meeting]]))
            }
            return (404, Data())
        }
        #expect(review.canDiscard && failed.canDiscard)
        for status in ["queued", "uploading", "processing", "completed", "disposing"] {
            #expect(!AccountRecording(id: "x", status: status).canDiscard, "\(status) must not be discardable")
        }
        await fixture.signIn()
        let account = try #require(model.account)

        // 204: DELETE through the injected transport, then a forced sync drops the recording.
        let getsBefore = gets
        try await model.discardRecording(meetingId: meeting.id, recording: review, from: account)
        let first = try #require(deletes.last)
        #expect(first.path.hasSuffix("/account/v1/meetings/\(meeting.id)/recordings/\(review.id)"))
        #expect(first.auth == "Bearer fixture-A")
        #expect(gets == getsBefore + 1)
        #expect(model.cache.visible.first?.recordings.map(\.id) == [failed.id])

        // 409 recording_active: no sync, readable message through run().
        deleteStatus = 409
        let getsBeforeConflict = gets
        var caught: Error?
        do { try await model.discardRecording(meetingId: meeting.id, recording: failed, from: account) }
        catch { caught = error }
        guard case AccountAgendaError.response(409, "recording_active")? = caught else {
            Issue.record("unexpected \(String(describing: caught))"); return
        }
        #expect(gets == getsBeforeConflict)
        #expect(deletes.count == 2)
        await model.run { try await model.discardRecording(meetingId: meeting.id, recording: failed, from: account) }
        #expect(model.message == AccountAgendaError.response(409, "recording_active").localizedDescription)
        #expect(!model.message.contains("HTTP"))
        #expect(model.cache.visible.first?.recordings.map(\.id) == [failed.id])

        // Active recordings and other accounts are refused before any request.
        let count = deletes.count
        await #expect(throws: AccountAgendaError.self) {
            try await model.discardRecording(meetingId: meeting.id, recording: .init(id: "rec-live", status: "processing"), from: account)
        }
        var otherUser = account
        otherUser.credentials.userId = "test-B"
        await #expect(throws: AccountAgendaError.self) {
            try await model.discardRecording(meetingId: meeting.id, recording: failed, from: otherUser)
        }
        #expect(deletes.count == count)
    }
}
