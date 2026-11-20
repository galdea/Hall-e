import Foundation
import Security
import Testing
@testable import HallE

private struct NativeFixture: Decodable {
    let origin: String
    let certificate: String?
    let desktop: AccountCredentials
    let stranger: AccountCredentials
    let meetingId: String
    let project: AccountProject
}

private struct ImportedOccurrence: Encodable {
    let meetingId: String
    let project: AccountProject
}

/// Trust only the fixture's certificate and refuse redirects before sending synthetic credentials.
private final class NativeLoopbackTrust: NSObject, URLSessionTaskDelegate {
    let port: Int
    let certificate: SecCertificate

    init(port: Int, pem: URL) throws {
        let base64 = try String(contentsOf: pem, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }.joined()
        let bytes = try #require(Data(base64Encoded: base64))
        self.certificate = try #require(SecCertificateCreateWithData(nil, bytes as CFData))
        self.port = port
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1", space.port == port,
              let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              CFEqual(leaf, certificate),
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@Suite("Native private account interoperability")
struct NativeAccountInteropTests {
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["HALL_E_NATIVE_QA"] != nil))
    func nativeAccountRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let fixturePath = try #require(env["HALL_E_NATIVE_QA"])
        let phase = try #require(env["HALL_E_NATIVE_PHASE"])
        try #require(["create", "verify"].contains(phase))
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixture = try JSONDecoder().decode(NativeFixture.self, from: Data(contentsOf: fixtureURL))
        let origin = try AccountAPI.origin(fixture.origin)
        let hosted = fixture.certificate == nil
        let delegate: URLSessionTaskDelegate
        if let certificate = fixture.certificate {
            try #require(origin.host == "127.0.0.1")
            let port = try #require(origin.port)
            delegate = try NativeLoopbackTrust(port: port, pem: URL(fileURLWithPath: certificate))
        } else {
            try #require(origin.absoluteString == "https://halle-account-staging.gabriel-aldea.workers.dev")
            try #require(env["HALLE_STAGE_ORIGIN"] == origin.absoluteString)
            delegate = AccountRedirectPolicy()
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let cacheRoot = fixtureURL.deletingLastPathComponent().appendingPathComponent("swift-agenda", isDirectory: true)
        let suite = "test.halle.native." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.set(true, forKey: "private-agenda-initialized-v1")
        defer { preferences.removePersistentDomain(forName: suite) }

        // Restore the same session as a returning app. Both clients use an in-memory credential vault.
        struct TestVault: Encodable {
            let active: AccountConnection
            let revocations: [AccountConnection] = []
        }
        func device(_ credentials: AccountCredentials) async throws -> AccountAgendaModel {
            let connection = AccountConnection(origin: origin, credentials: credentials)
            var vault = String(decoding: try JSONEncoder().encode(TestVault(active: connection)), as: UTF8.self)
            let model = AccountAgendaModel(preferences: preferences, cacheRoot: { cacheRoot },
                                          loadVault: { vault }, saveVault: { vault = $0 }, transport: session)
            await model.run {}
            guard model.canEdit else { throw AccountAgendaError.session }
            return model
        }

        let desktop = try await device(fixture.desktop)
        let account = try #require(desktop.account)
        let start = Date(timeIntervalSince1970: 1_798_221_600)
        let local = Project(id: "synthetic-local-project", name: "Synthetic archive project", aliases: [])
        let event = UnifiedEvent(dedupKey: "synthetic-local-\(fixture.meetingId)", title: "Synthetic imported meeting",
                                 startTs: start, endTs: start.addingTimeInterval(1_800),
                                 isAllDay: false, status: "confirmed", iCalUID: "synthetic-local-series",
                                 winnerAccountEmail: "host@example.invalid", projectId: nil, sourcesJSON: "[]")
        var decisions = LocalProjectDecisions()
        decisions.occurrences[event.id] = .init(dedupKey: event.id, projectId: local.id, updatedAt: start)
        let confirmed = try #require(AccountProject.confirmedCopy(for: event, decisions: decisions, projects: [local],
                                                                  account: account, existing: []))
        let importedID = AccountCalendarCache.importID(source: event.dedupKey, origin: origin,
                                                      userId: fixture.desktop.userId)
        if phase == "create" {
            let draft = AccountMeeting.draft(id: fixture.meetingId, title: "Synthetic native meeting")
            // Record both IDs before writing remotely so a failed synchronization can be cleaned up.
            let cleanup = fixtureURL.deletingLastPathComponent().appendingPathComponent("swift-cleanup.json")
            try JSONEncoder().encode([draft.id, importedID]).write(to: cleanup, options: .withoutOverwriting)
            try desktop.enqueue(draft)
            try desktop.importOccurrence(event, project: confirmed, into: account)
            try await desktop.synchronize()
            try #require(desktop.cache.pending.isEmpty)
            let saved = try #require(desktop.cache.visible.first { $0.id == draft.id })
            try #require(saved.revision == 1 && saved.project == nil && saved.recordings.isEmpty)
            let imported = try #require(desktop.cache.visible.first { $0.id == importedID })
            try #require(imported.title == event.title && imported.project == confirmed && imported.revision == 1)
            let receipt = ImportedOccurrence(meetingId: importedID, project: confirmed)
            let file = fixtureURL.deletingLastPathComponent().appendingPathComponent("swift-import.json")
            try JSONEncoder().encode(receipt).write(to: file, options: .withoutOverwriting)
        } else {
            // The Mac process has restarted. An incremental refresh must expose the phone's edits.
            let previous = try #require(desktop.cache.visible.first { $0.id == fixture.meetingId })
            try #require(previous.project == nil && previous.recordings.isEmpty)
            try #require(desktop.cache.version != nil)
            try await desktop.synchronize()
            let meetings = desktop.cache.visible.filter { $0.id == fixture.meetingId }
            try #require(meetings.count == 1)
            try #require(meetings[0].project == fixture.project)
            let recordings = meetings[0].recordings
            try #require(recordings.count == 1)
            try #require(recordings[0].status == "completed")
            let expected = hosted ? "[STAGING SYNTHETIC]" : "Synthetic native transcript."
            try #require(recordings[0].transcript?.contains(expected) == true)
            let imported = try #require(desktop.cache.visible.first { $0.id == importedID })
            try #require(imported.project == confirmed && imported.recordings.isEmpty)
        }

        let other = try await device(fixture.stranger)
        let privateIDs = [fixture.meetingId, importedID]
        try #require(!other.cache.visible.contains { privateIDs.contains($0.id) })
        try await other.synchronize()
        try #require(!other.cache.visible.contains { privateIDs.contains($0.id) })
        if phase == "verify" {
            let receipt = fixtureURL.deletingLastPathComponent().appendingPathComponent("swift-verified")
            try Data(fixture.meetingId.utf8).write(to: receipt, options: .withoutOverwriting)
        }
    }
}
