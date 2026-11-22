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
    /// Capabilities from `GET auth/session`, fetched once per connection. Unknown or missing means none.
    private(set) var features = AccountFeatures()
    private var featuresFor: AccountConnection?
    /// On-demand transcript text per recording, keyed by `transcriptKey`.
    private(set) var transcriptStates: [String: AccountTranscriptState] = [:]
    private func file(_ connection: AccountConnection) -> URL {
        AccountCalendarCache.file(in: cacheRoot(), origin: connection.origin, userId: connection.credentials.userId)
    }
    private func transcripts(_ connection: AccountConnection) -> AccountTranscriptCache {
        AccountTranscriptCache(root: cacheRoot(), origin: connection.origin, userId: connection.credentials.userId)
    }
    private static func transcriptKey(_ meetingId: String, _ recordingId: String) -> String {
        meetingId.lowercased() + "/" + recordingId.lowercased()
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
        transcriptStates = [:]
        try openCache(connection)
        message = ""
        try await synchronize()
    }

    func signOut() async throws {
        try await clearActive(queueRevocation: true)
        await retryRevocations()
        message = vault.revocations.isEmpty ? "" : PublicUICopy.text("Signed out locally. Server revocation is queued.", "Sesión cerrada en el Mac. Queda pendiente la revocación en el servidor.")
    }

    /// Signs this Mac out of the active account. The calendar cache file stays on disk so queued
    /// offline edits survive a later sign-in; fetched transcript text is removed because it can be
    /// fetched again and should not outlive the session on this Mac.
    private func clearActive(queueRevocation: Bool) async throws {
        var next = vault
        let old = next.active
        if let old, queueRevocation && !old.expired { next.revocations.append(old) }
        next.active = nil
        try await store(next)
        if let old { transcripts(old).removeAll() }
        resetSignedOutState()
    }

    private func resetSignedOutState() {
        cache = .init()
        cacheReady = false
        features = .init()
        featuresFor = nil
        transcriptStates = [:]
        resetChallenge()
        email = ""
    }

    /// Permanently deletes the signed-in account on the service (ADR 0007). Only a `202` changes
    /// anything here: then this account's calendar cache, fetched transcripts and stored session are
    /// removed and the Mac returns to the signed-out state. The deleted session is not revoked again.
    /// Recordings and transcripts in the Mac library are untouched.
    func deleteAccount(confirmation: String) async throws {
        guard confirmation.trimmingCharacters(in: .whitespacesAndNewlines) == "DELETE" else {
            throw AccountAgendaError.deletionConfirmation
        }
        guard let account, !account.expired else { throw AccountAgendaError.session }
        let status: Int
        do {
            status = try await api(account.origin).request("POST", "account/delete", token: account.credentials.token,
                                                           body: ["confirmation": "DELETE"]).0
        } catch AccountAgendaError.response(let status, let code) {
            throw AccountAgendaError.deletionFailed(status, code)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw AccountAgendaError.deletionFailed(0, "network")
        }
        guard status == 202 else { throw AccountAgendaError.deletionFailed(status, "unexpected_status") }
        try? FileManager.default.removeItem(at: file(account))
        transcripts(account).removeAll()
        var next = vault
        // Every session of this user is already revoked by the server; queued revocations for it would only fail.
        next.revocations.removeAll { $0.origin == account.origin && $0.credentials.userId == account.credentials.userId }
        if next.active == account { next.active = nil }
        try await store(next)
        resetSignedOutState()
        message = PublicUICopy.text("The account was deleted. Recordings on this Mac were kept.",
                                    "La cuenta se eliminó. Las grabaciones de este Mac se conservaron.")
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

    /// What to show for a recording's transcript right now. Inline text wins; otherwise the result of
    /// the last `loadTranscript` call for this recording, or `.idle` before one.
    func transcriptState(meetingId: String, recording: AccountRecording) -> AccountTranscriptState {
        if let inline = recording.inlineTranscript { return .loaded(inline) }
        return transcriptStates[Self.transcriptKey(meetingId, recording.id)] ?? .idle
    }

    /// Fetches a recording's transcript when it is not in the agenda: first from this account's
    /// on-disk transcript cache, then from `GET meetings/:id/recordings/:rid/transcript`, which is
    /// then cached. Errors become a `.failed` state for that recording only. A `force` reload skips
    /// an earlier result held in memory (for a retry after an error).
    @discardableResult
    func loadTranscript(meetingId: String, recording: AccountRecording, force: Bool = false) async -> AccountTranscriptState {
        if let inline = recording.inlineTranscript { return .loaded(inline) }
        let key = Self.transcriptKey(meetingId, recording.id)
        guard let account, cacheReady else {
            return .failed(AccountAgendaError.session.localizedDescription)
        }
        switch transcriptStates[key] {
        case .loading?: return .loading
        case .loaded(let text)? where !force: return .loaded(text)
        default: break
        }
        guard recording.transcriptIsRemote else {
            let state = AccountTranscriptState.failed(Self.transcriptUnavailable)
            transcriptStates[key] = state
            return state
        }
        let store = transcripts(account)
        if let text = store.load(meetingId: meetingId, recordingId: recording.id) {
            transcriptStates[key] = .loaded(text)
            return .loaded(text)
        }
        transcriptStates[key] = .loading
        let state: AccountTranscriptState
        do {
            let (_, data) = try await api(account.origin).request(
                "GET", "meetings/\(meetingId)/recordings/\(recording.id)/transcript", token: account.credentials.token)
            guard let text = String(data: data, encoding: .utf8) else { throw AccountAgendaError.invalidResponse }
            // Sign-out, account switch or a sync that dropped the recording while this was in flight wins.
            guard self.account == account, cacheReady, recordingIsListed(meetingId: meetingId, recordingId: recording.id) else {
                if self.account == account { transcriptStates[key] = nil }
                return .idle
            }
            try? store.save(text, meetingId: meetingId, recordingId: recording.id)
            state = .loaded(text)
        } catch AccountAgendaError.response(404, _) {
            state = .failed(Self.transcriptUnavailable)
        } catch is CancellationError {
            if self.account == account { transcriptStates[key] = nil }
            return .idle
        } catch {
            state = .failed(PublicUICopy.text("The transcript could not be loaded.", "No se pudo cargar la transcripción.")
                            + " " + error.localizedDescription)
        }
        guard self.account == account else { return .idle }
        transcriptStates[key] = state
        return state
    }

    private static var transcriptUnavailable: String {
        PublicUICopy.text("This transcript is not available.", "Esta transcripción no está disponible.")
    }

    private func recordingIsListed(meetingId: String, recordingId: String) -> Bool {
        cache.meetings.contains { $0.id == meetingId && !$0.deleted && $0.recordings.contains { $0.id == recordingId } }
    }

    /// Drops cached transcript text for recordings that left the agenda or now carry their text inline.
    private func evictTranscripts(_ account: AccountConnection, keeping meetings: [AccountMeeting]) {
        let remote = meetings.filter { !$0.deleted }.flatMap { meeting in
            meeting.recordings.filter(\.transcriptIsRemote).map { (meetingId: meeting.id, recordingId: $0.id) }
        }
        transcripts(account).retain(remote)
        let keys = Set(remote.map { Self.transcriptKey($0.meetingId, $0.recordingId) })
        transcriptStates = transcriptStates.filter { keys.contains($0.key) }
    }

    /// Reads `features` from `GET auth/session` once per connection. A `401` ends the session like any
    /// other request; other answers without usable features mean no optional features. Transport
    /// failures leave the capabilities unknown so the next sync asks again.
    private func refreshFeatures(_ account: AccountConnection, api: AccountAPI) async throws {
        struct Session: Decodable { var features: AccountFeatures? }
        do {
            let session = try await api.json(Session.self, "GET", "auth/session", token: account.credentials.token)
            features = session.features ?? .init()
            featuresFor = account
        } catch AccountAgendaError.response(401, let code) {
            throw AccountAgendaError.response(401, code)
        } catch AccountAgendaError.response {
            features = .init()
            featuresFor = account
        } catch is DecodingError {
            features = .init()
            featuresFor = account
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            features = .init()
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
            if featuresFor != account { try await refreshFeatures(account, api: api) }
            guard self.account == account else { return }
            // Without a fresh answer from auth/session, keep the mode the cache was last filled in.
            let lazy = featuresFor == account ? features.lazyTranscripts : (cache.lazyTranscripts ?? false)
            let sameMode = (cache.lazyTranscripts ?? false) == lazy
            let version = force || !sameMode || cache.pending.contains(where: { !$0.conflict }) ? nil : cache.version
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
            var query = lazy ? [URLQueryItem(name: "transcripts", value: "lazy")] : []
            if let version { query.append(URLQueryItem(name: "since", value: version)) }
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
                next.lazyTranscripts = lazy
                try update(next)
                evictTranscripts(account, keeping: meetings)
            }
            message = PublicUICopy.text("Synced", "Sincronizado") + " · " + Date.now.formatted(date: .omitted, time: .shortened)
        } catch AccountAgendaError.response(401, _) {
            try await clearActive(queueRevocation: false)
            throw AccountAgendaError.session
        }
    }
}
