import Testing
import Foundation
import GRDB
@testable import HallE

@Suite("Local call capture")
struct CallCaptureTests {
    private let now = Date()

    @Test func normalizesKnownProviderURLsWithoutTrackingQuery() {
        let meet = CallIdentity.make(url: URL(string: "https://meet.google.com/AbC-dEfG-hIj?authuser=0#x")!)
        #expect(meet?.provider == .googleMeet)
        #expect(meet?.normalizedURL == "https://meet.google.com/abc-defg-hij")

        let zoom = CallIdentity.make(url: URL(string: "https://acme.zoom.us/j/987654321?pwd=private")!)
        #expect(zoom?.provider == .zoom)
        #expect(zoom?.normalizedURL == "https://acme.zoom.us/j/987654321")
    }

    @Test func rejectsUnapprovedDomainAndAcceptsExplicitCustomDomain() {
        let url = URL(string: "https://calls.example.test/room/one?token=secret")!
        #expect(CallIdentity.make(url: url, customDomains: []) == nil)
        let identity = CallIdentity.make(url: url, customDomains: ["calls.example.test"])
        #expect(identity?.provider == .custom)
        #expect(identity?.normalizedURL == "https://calls.example.test/room/one")
    }

    @Test func onlyExactNearbyURLMatchesCalendarEvent() {
        let matching = event(key: "matching", url: "https://meet.google.com/abc-defg-hij", start: now.addingTimeInterval(-60))
        let differentRoom = event(key: "other", url: "https://meet.google.com/xxx-yyyy-zzz", start: now)
        let stale = event(key: "stale", url: "https://meet.google.com/abc-defg-hij", start: now.addingTimeInterval(-9 * 60 * 60))
        let identity = CallIdentity.make(url: URL(string: "https://meet.google.com/ABC-DEFG-HIJ?x=1")!)!
        #expect(CallEventMatcher.match(identity, in: [differentRoom, stale, matching], detectedAt: now)?.dedupKey == "matching")
    }

    @Test func debouncerSuppressesRepeatAndAllowsCallEndToReset() {
        let identity = CallIdentity(provider: .googleMeet, normalizedURL: "https://meet.google.com/abc-defg-hij")
        let debouncer = CallPromptDebouncer(interval: 90)
        #expect(debouncer.shouldPrompt(identity: identity, tabID: 3, now: now))
        #expect(!debouncer.shouldPrompt(identity: identity, tabID: 3, now: now.addingTimeInterval(1)))
        debouncer.end(identity: identity, tabID: 3)
        #expect(debouncer.shouldPrompt(identity: identity, tabID: 3, now: now.addingTimeInterval(2)))
    }

    @Test func nativePayloadValidationAndDurableQueueRejectMalformedMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halle-call-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let good: [String: Any] = ["version": 1, "type": "opened", "tabId": 8,
                                   "url": "https://meet.google.com/abc-defg-hij?x=1",
                                   "title": "Team sync", "detectedAt": now.timeIntervalSince1970 * 1_000]
        let data = try JSONSerialization.data(withJSONObject: good)
        #expect(BrowserCallMessageQueue.enqueue(rawPayload: data, directory: directory, customDomains: []))
        let launches = BrowserCallMessageQueue.drain(directory: directory, customDomains: [])
        #expect(launches.count == 1)
        #expect(launches.first?.tabID == 8)
        #expect(BrowserCallMessageQueue.drain(directory: directory, customDomains: []).isEmpty)

        let bad = Data("{\"version\":1,\"type\":\"opened\",\"url\":\"https://not-approved.test/call\",\"detectedAt\":0}".utf8)
        #expect(!BrowserCallMessageQueue.enqueue(rawPayload: bad, directory: directory, customDomains: []))
    }

    @Test func bundledExtensionRetainsChromeDirectoryLayout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halle-extension-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try ChromeNativeHostInstaller.prepareExtension(destination: directory)
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("manifest.json").path))
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("service-worker.js").path))
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("options.html").path))
    }

    @Test func localCaptureEventIsSeparateFromGoogleCalendarRows() throws {
        let database = try AppDatabase(inMemory: true)
        let identity = CallIdentity(provider: .googleMeet, normalizedURL: "https://meet.google.com/abc-defg-hij")
        let local = LocalCaptureEvent(identity: identity, title: "Browser call", startedAt: now)
        try database.dbQueue.write { db in try local.insert(db) }

        let result = try database.dbQueue.read { db in
            (try LocalCaptureEvent.fetchCount(db), try CalendarEvent.fetchCount(db), try UnifiedEvent.fetchCount(db))
        }
        #expect(result.0 == 1)
        #expect(result.1 == 0)
        #expect(result.2 == 0)
        #expect(local.unifiedEvent.dedupKey == "local:\(local.id)")
    }

    private func event(key: String, url: String, start: Date) -> UnifiedEvent {
        UnifiedEvent(dedupKey: key, title: key, startTs: start, endTs: start.addingTimeInterval(60 * 60),
                     isAllDay: false, status: "confirmed", effectiveResponse: "accepted", meetingURL: url,
                     location: nil, descriptionText: nil, htmlLink: nil, organizerEmail: nil,
                     attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: "person@example.com",
                     projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
    }
}
