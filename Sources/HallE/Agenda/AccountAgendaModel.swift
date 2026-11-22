import AppKit
import Observation

struct AccountCredentials: Codable, Equatable {
    var userId: String
    var token: String
    var expiresAt: Double  // Unix milliseconds
}

struct AccountConnection: Codable, Equatable {
    var origin: URL
    var credentials: AccountCredentials
    var expired: Bool { Date().timeIntervalSince1970 * 1000 >= credentials.expiresAt }
}

private struct AccountVault: Codable {
    var active: AccountConnection?
    var revocations: [AccountConnection] = []
}

@Observable @MainActor
final class AccountAgendaModel {
    static let shared = makeShared()
    fileprivate static let vaultKey = "private-agenda-sessions-v1"
    private static let optInKey = "private-agenda-initialized-v1"
    private static let originKey = "private-agenda-origin-v1"

    static func makeShared(environment: [String: String] = ProcessInfo.processInfo.environment) -> AccountAgendaModel {
        #if DEBUG
        if environment["HALLE_DEBUG_FIXTURES"] == "1" {
            // One fixed, wiped suite: never the real preferences, and no new plist per launch.
            let suite = "cl.gabriel.hall-e.debug-fixtures"
            let prefs = UserDefaults(suiteName: suite) ?? UserDefaults()
            prefs.removePersistentDomain(forName: suite)
            var inMemoryVault: String?
            return AccountAgendaModel(
                preferences: prefs,
                loadVault: { inMemoryVault },
                saveVault: { inMemoryVault = $0 }
            )
        }
        #endif
        return AccountAgendaModel()
    }

    private let preferences: UserDefaults
    private let cacheRoot: () -> URL
    private let loadVault: () async throws -> String?
    private let saveVault: (String) async throws -> Void
    private let transport: URLSession
    private let openURL: (URL) -> Bool
    private let stagingOrigin: URL?

    init(preferences: UserDefaults = .standard,
         cacheRoot: @escaping () -> URL = { AppPaths.appSupport.appendingPathComponent("PrivateAgenda", isDirectory: true) },
         loadVault: @escaping () async throws -> String? = { try await KeychainStore.getAsync(account: AccountAgendaModel.vaultKey) },
         saveVault: @escaping (String) async throws -> Void = { try await KeychainStore.setAsync($0, account: AccountAgendaModel.vaultKey) },
         transport: URLSession = AccountAPI.session,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         packagedOrigin: String? = Bundle.main.object(forInfoDictionaryKey: "HallEAccountOrigin") as? String) {
        self.preferences = preferences
        self.cacheRoot = cacheRoot
        self.loadVault = loadVault
        self.saveVault = saveVault
        self.transport = transport
        self.openURL = openURL
        self.stagingOrigin = AppPaths.isStaging ? (try? AccountAPI.origin(packagedOrigin ?? "")) : nil
        let preferredOrigin = preferences.string(forKey: Self.originKey) ?? packagedOrigin ?? ""
        self.endpoint = (try? AccountAPI.origin(preferredOrigin))?.absoluteString ?? ""
    }

    private func api(_ origin: URL) -> AccountAPI { AccountAPI(origin: origin, session: transport) }

    var usesStagingMailbox: Bool {
        guard let stagingOrigin else { return false }
        return (try? AccountAPI.origin(endpoint)) == stagingOrigin
    }

    var endpoint = ""
    var email = ""
    var code = ""
    private(set) var challenge: String?
    private(set) var busy = false
    var confirmationCode = ""
    private var browserToken: String?
    var waitingForBrowser: Bool { browserToken != nil }
    private(set) var message = ""
    private(set) var cache = AccountCalendarCache()
    private var cacheReady = false
    private var initialized = false
    private var vault = AccountVault()
    private var challengeOrigin: URL?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var account: AccountConnection? { vault.active }
    var canEdit: Bool { account != nil && cacheReady }
    private func file(_ connection: AccountConnection) -> URL {
        AccountCalendarCache.file(in: cacheRoot(), origin: connection.origin, userId: connection.credentials.userId)
    }

    func run(background: Bool = false, _ operation: () async throws -> Void) async {
        if busy {
            if background { return }
            await withCheckedContinuation { waiters.append($0) }
            if Task.isCancelled {
                releaseRunSlot()
                return
            }
        } else {
            busy = true
        }
        defer { releaseRunSlot() }
        do {
            try await initialize()
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    private func releaseRunSlot() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            busy = false
        }
    }

    private func initialize() async throws {
        guard !initialized else { return }
        if preferences.bool(forKey: Self.optInKey),
           let stored = try await loadVault() {
            vault = try JSONDecoder().decode(AccountVault.self, from: Data(stored.utf8))
        }
        initialized = true
        if let account {
            endpoint = account.origin.absoluteString
            preferences.set(endpoint, forKey: Self.originKey)
            if account.expired {
                try await clearActive(queueRevocation: false)
            } else { try openCache(account) }
        }
    }

    private func store(_ next: AccountVault) async throws {
        let encoded = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        try await saveVault(encoded)
        preferences.set(true, forKey: Self.optInKey)
        vault = next
    }

    private func openCache(_ connection: AccountConnection) throws {
        cacheReady = false
        cache = try AccountCalendarCache.load(from: file(connection))
        cacheReady = true
    }

    private func update(_ next: AccountCalendarCache) throws {
        guard let account, cacheReady else { throw AccountAgendaError.session }
        try next.save(to: file(account))
        cache = next
    }

    func resetChallenge() {
        challenge = nil
        challengeOrigin = nil
        code = ""
        browserToken = nil
        confirmationCode = ""
    }

    private func authContext() throws -> (AccountAPI, String?) {
        let origin = try AccountAPI.origin(endpoint)
        guard account == nil || account?.origin == origin else { throw AccountAgendaError.origin }
        preferences.set(origin.absoluteString, forKey: Self.originKey)
        return (api(origin), account?.credentials.token)
    }

    func startEmail() async throws {
        struct Start: Decodable { var challengeId: String }
        resetChallenge()
        let (api, token) = try authContext()
        let result = try await api.json(Start.self, "POST", "auth/email/start", token: token,
                                        body: ["email": email, "link": token != nil])
        challenge = result.challengeId
        challengeOrigin = api.origin
        message = usesStagingMailbox
            ? PublicUICopy.text("Open Hall-e Staging Code.command on the Mac to get the eight digits for this sign-in.",
                                "Abre Hall-e Staging Code.command en el Mac para obtener los ocho dígitos de este inicio de sesión.")
            : PublicUICopy.text("Enter the code sent to your email.", "Introduce el código enviado a tu correo.")
    }

    func finishEmail() async throws {
        let (api, token) = try authContext()
        guard let challenge, challengeOrigin == api.origin else { throw AccountAgendaError.origin }
        let credentials = try await api.json(AccountCredentials.self, "POST", "auth/email/verify", token: token,
                                            body: ["challengeId": challenge, "code": code])
        try await connect(credentials, api.origin)
    }

    func google() async throws {
        struct Start: Decodable { var url: URL; var pollToken: String }
        resetChallenge()
        let (api, token) = try authContext()
        let start = try await api.json(Start.self, "POST", "auth/browser/start", token: token, body: ["link": token != nil])
        guard let c = URLComponents(url: start.url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host == "accounts.google.com", c.port == nil, c.user == nil,
              c.password == nil, c.path == "/o/oauth2/v2/auth", openURL(start.url) else { throw AccountAgendaError.browser }
        browserToken = start.pollToken
        challengeOrigin = api.origin
        message = PublicUICopy.text("Enter the confirmation code shown by Hall-e in your browser.", "Introduce el código de confirmación que Hall-e muestra en el navegador.")
    }

    func finishGoogle() async throws {
        let (api, token) = try authContext()
        guard api.origin == challengeOrigin, let browserToken, confirmationCode.range(of: "^[0-9]{8}$", options: .regularExpression) != nil
        else { throw AccountAgendaError.invalidResponse }
        do {
            let (status, data) = try await api.request("POST", "auth/browser/finish", token: token,
                                                      body: ["pollToken": browserToken, "confirmationCode": confirmationCode])
            if status == 202 {
                message = PublicUICopy.text("Finish signing in in your browser, then confirm here.", "Termina el inicio de sesión en el navegador y confirma aquí.")
                return
            }
            guard status == 200 else { throw AccountAgendaError.invalidResponse }
            try await connect(try JSONDecoder().decode(AccountCredentials.self, from: data), api.origin)
        } catch AccountAgendaError.response(let status, let code) {
            if [403, 409, 410].contains(status) { resetChallenge() }
            throw AccountAgendaError.response(status, code)
        }
    }

    private func connect(_ creds: AccountCredentials, _ origin: URL) async throws {
        guard !creds.userId.isEmpty, !creds.token.isEmpty, creds.expiresAt > Date().timeIntervalSince1970 * 1000,
              account == nil || (account?.origin == origin && account?.credentials.userId == creds.userId)
        else { throw AccountAgendaError.invalidResponse }
        var next = vault
        if let previous = next.active, previous.credentials.token != creds.token {
            next.revocations.append(previous)
        }
        let connection = AccountConnection(origin: origin, credentials: creds)
        next.active = connection
        try await store(next)
        resetChallenge()
        email = ""
        endpoint = origin.absoluteString
        cache = .init()
        try openCache(connection)
        message = ""
        try await synchronize()
    }

    func signOut() async throws {
        try await clearActive(queueRevocation: true)
        await retryRevocations()
        message = vault.revocations.isEmpty ? "" : PublicUICopy.text("Signed out locally. Server revocation is queued.", "Sesión cerrada en el Mac. Queda pendiente la revocación en el servidor.")
    }

    private func clearActive(queueRevocation: Bool) async throws {
        var next = vault
        if let old = next.active, queueRevocation && !old.expired { next.revocations.append(old) }
        next.active = nil
        try await store(next)
        cache = .init()
        cacheReady = false
        resetChallenge()
        email = ""
    }

    private func retryRevocations() async {
        for old in vault.revocations {
            if !old.expired {
                do { _ = try await api(old.origin).request("POST", "auth/logout", token: old.credentials.token, body: [:]) }
                catch AccountAgendaError.response(401, _) { /* already revoked */ }
                catch { continue }
            }
            var next = vault
            next.revocations.removeAll { $0 == old }
            try? await store(next)
        }
    }

    func periodicSync() async {
        while !Task.isCancelled {
            if preferences.bool(forKey: Self.optInKey) { await run(background: true) { try await synchronize() } }
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
        }
    }

    static func transcriptImportID(meetingId: String, sessionId: UUID, account: AccountConnection) -> String {
        AccountCalendarCache.importID(source: "local-transcript:\(meetingId):\(sessionId.uuidString)",
                                      origin: account.origin,
                                      userId: account.credentials.userId)
    }

    func importTranscript(meetingId: String, importId: String, text: String, into expected: AccountConnection) async throws {
        guard account == expected else { throw AccountAgendaError.session }
        _ = try await api(expected.origin).request(
            "PUT", "meetings/\(meetingId)/imports/\(importId)",
            token: expected.credentials.token, body: ["consent": true, "transcript": text]
        )
        try await synchronize(force: true)
    }

    func removeImportedTranscript(meetingId: String, importId: String, from expected: AccountConnection) async throws {
        guard account == expected else { throw AccountAgendaError.session }
        _ = try await api(expected.origin).request(
            "DELETE", "meetings/\(meetingId)/imports/\(importId)",
            token: expected.credentials.token
        )
        try await synchronize(force: true)
    }

    /// Ends a recording the service stopped on (`review` or `failed`). Only the owner can do this.
    func discardRecording(meetingId: String, recording: AccountRecording, from expected: AccountConnection) async throws {
        guard account == expected else { throw AccountAgendaError.session }
        guard recording.canDiscard else { throw AccountAgendaError.response(409, "recording_active") }
        _ = try await api(expected.origin).request(
            "DELETE", "meetings/\(meetingId)/recordings/\(recording.id)",
            token: expected.credentials.token
        )
        try await synchronize(force: true)
    }

    func enqueue(_ meeting: AccountMeeting) throws {
        var next = cache
        try next.enqueue(meeting)
        try update(next)
        message = PublicUICopy.text("Saved on this Mac. Waiting to sync.", "Guardada en este Mac. Pendiente de sincronización.")
    }

    func importOccurrence(_ occurrence: UnifiedEvent, project: AccountProject?, into expected: AccountConnection) throws {
        guard account == expected else { throw AccountAgendaError.session }
        var next = cache
        if try next.importOccurrence(occurrence, project: project, into: expected) {
            try update(next)
            message = PublicUICopy.text("Saved on this Mac. Waiting to sync.", "Guardada en este Mac. Pendiente de sincronización.")
        } else {
            message = PublicUICopy.text("This occurrence has already been copied.", "Ya se copió esta reunión.")
        }
    }

    func reapply(_ mutation: AgendaMutation) throws {
        var next = cache
        try next.reapply(mutation)
        try update(next)
    }

    func keepServerVersion(_ mutation: AgendaMutation) throws {
        var next = cache
        next.pending.removeAll { $0.id == mutation.id && $0.conflict }
        try update(next)
    }

    func conflict(for mutation: AgendaMutation) -> AgendaConflict { cache.conflict(for: mutation) }

    func saveAsNewMeeting(_ mutation: AgendaMutation) throws {
        var next = cache
        try next.saveAsNew(mutation)
        try update(next)
        message = PublicUICopy.text("Saved on this Mac as a new meeting. Waiting to sync.",
                                    "Guardada en este Mac como una reunión nueva. Pendiente de sincronización.")
    }

    func synchronize(force: Bool = false) async throws {
        await retryRevocations()
        guard let account else { return }
        do {
            if account.expired { throw AccountAgendaError.response(401, "session_expired") }
            if !cacheReady { try openCache(account) }
            let api = api(account.origin)
            let version = force || cache.pending.contains(where: { !$0.conflict }) ? nil : cache.version
            for edit in cache.pending where !edit.conflict {
                do {
                    struct Result: Decodable { let meeting: AccountMeeting }
                    let result = try await api.json(Result.self, "PUT", "meetings/\(edit.meeting.id)",
                                                    token: account.credentials.token, body: edit.body)
                    guard result.meeting.id == edit.meeting.id else { throw AccountAgendaError.invalidResponse }
                    var next = cache
                    next.acknowledge(edit, result: result.meeting)
                    try update(next)
                } catch AccountAgendaError.response(let status, _) where status >= 400 && status < 500 && ![401, 408, 425, 429].contains(status) {
                    var next = cache
                    if let i = next.pending.firstIndex(where: { $0.id == edit.id }) { next.pending[i].conflict = true }
                    try update(next)
                }
            }
            struct CalendarResponse: Decodable {
                var meetings: [AccountMeeting]?
                var unchanged: Bool?
                var version: String?
            }
            let query = version.map { [URLQueryItem(name: "since", value: $0)] } ?? []
            let remote = try await api.json(CalendarResponse.self, "GET", "meetings", token: account.credentials.token, query: query)
            if let nextVersion = remote.version, nextVersion.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == nil {
                throw AccountAgendaError.invalidResponse
            }
            if remote.unchanged == true {
                guard version != nil, version == remote.version, remote.meetings == nil else { throw AccountAgendaError.invalidResponse }
            } else {
                guard let meetings = remote.meetings, meetings.allSatisfy({ UUID(uuidString: $0.id) != nil }) else {
                    throw AccountAgendaError.invalidResponse
                }
                var next = cache
                next.meetings = meetings
                next.version = remote.version
                try update(next)
            }
            message = PublicUICopy.text("Synced", "Sincronizado") + " · " + Date.now.formatted(date: .omitted, time: .shortened)
        } catch AccountAgendaError.response(401, _) {
            try await clearActive(queueRevocation: false)
            throw AccountAgendaError.session
        }
    }
}
