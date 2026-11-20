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

@Suite("Private account agenda", .serialized)
struct AccountAgendaTests {
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
        func device() -> AccountAgendaModel {
            AccountAgendaModel(preferences: prefs, cacheRoot: { root }, loadVault: { fakeVault },
                               saveVault: { fakeVault = $0 }, transport: transport)
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
        let first = device()
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
}
