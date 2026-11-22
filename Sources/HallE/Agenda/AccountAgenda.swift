import Foundation
import CryptoKit

struct AccountProject: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String

    static func confirmedCopy(for event: UnifiedEvent, decisions: LocalProjectDecisions, projects: [Project],
                              account: AccountConnection, existing: [AccountProject]) -> Self? {
        guard case .assigned(let reference?) = decisions.decision(for: event) else { return nil }
        // Older decisions can contain a historical display name. Only a unique reference is safe to copy.
        let matches = projects.filter { $0.matchesReference(reference) }
        guard let project = projects.first(where: { $0.id == reference }) ?? (matches.count == 1 ? matches.first : nil),
              !project.isArchived else { return nil }
        let id = AccountCalendarCache.importID(source: "local-project:" + project.id, origin: account.origin,
                                              userId: account.credentials.userId)
        if let known = existing.first(where: { $0.id == id }) { return known }
        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 120, name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return Self(id: id, name: name)
    }
}

struct AccountRecording: Codable, Equatable, Identifiable {
    var id: String
    var status: String
    var transcript: String?
    var source: String? = nil

    /// The service stopped on this recording, so the owner may discard it.
    var canDiscard: Bool { status == "review" || status == "failed" }
}

struct AccountMeeting: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var startAt: String
    var endAt: String
    var revision: Int
    var deleted: Bool
    var recordings: [AccountRecording]
    var project: AccountProject?

    static func recordedOccurrences(outside agenda: [UnifiedEvent], recordings: [String: RecordingSession]) -> [UnifiedEvent] {
        let current = Set(agenda.map(\.dedupKey))
        return recordings.compactMap { key, session -> UnifiedEvent? in
            guard !current.contains(key), session.isFinished, session.eventDedupKey == key,
                  let event = session.eventSnapshot, event.dedupKey == key, event.status != "cancelled",
                  !event.isAllDay, event.endTs > event.startTs else { return nil }
            return event
        }.sorted { $0.startTs == $1.startTs ? $0.id < $1.id : $0.startTs > $1.startTs }
    }

    static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    static func date(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ??
        (try? Date(text, strategy: .iso8601))
    }

    func occurs(on day: Date, calendar: Calendar) -> Bool {
        guard !deleted, let start = Self.date(startAt), let end = Self.date(endAt),
              let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        return start < interval.end && (end > interval.start || start == interval.start)
    }

    static func draft(id: String = UUID().uuidString.lowercased(), title: String = "",
                      start: Date = .now, end: Date? = nil) -> Self {
        .init(id: id, title: title, startAt: timestamp(start), endAt: timestamp(end ?? start.addingTimeInterval(3600)),
              revision: 0, deleted: false, recordings: [])
    }
}

struct AgendaMutation: Codable, Identifiable {
    var meeting: AccountMeeting
    var mutationId = UUID().uuidString.lowercased()
    var conflict = false
    var projectChanged: Bool?
    var id: String { mutationId }
    var body: [String: Any] {
        var result: [String: Any] = ["title": meeting.title, "startAt": meeting.startAt, "endAt": meeting.endAt, "deleted": meeting.deleted,
         "baseRevision": meeting.revision, "mutationId": mutationId]
        if projectChanged == true {
            if let project = meeting.project { result["project"] = ["id": project.id, "name": project.name] }
            else { result["project"] = NSNull() }
        }
        return result
    }
}

/// A parked change beside the server's current copy of the same meeting.
struct AgendaConflict: Equatable {
    enum ServerState: Equatable {
        /// The server still has a live copy, possibly changed by another device.
        case live(AccountMeeting)
        /// Another device deleted the meeting; the tombstone is kept for reference.
        case deleted(AccountMeeting)
        /// The server never accepted this meeting (for example a rejected new meeting).
        case missing
    }

    let local: AccountMeeting
    let server: ServerState

    init(local: AccountMeeting, server: AccountMeeting?) {
        self.local = local
        if let server { self.server = server.deleted ? .deleted(server) : .live(server) }
        else { self.server = .missing }
    }

    /// The pending change itself was a delete.
    var localDeletes: Bool { local.deleted }
    /// Rebase the change onto the server's current revision.
    var canReapply: Bool { if case .live = server { return true } else { return false } }
    /// Only an edit can become a new meeting: a pending delete must never resurrect the meeting.
    var canSaveAsNew: Bool { !canReapply && !localDeletes }
}

struct AccountCalendarCache: Codable {
    var meetings: [AccountMeeting] = []
    var pending: [AgendaMutation] = []
    var version: String? = nil

    var visible: [AccountMeeting] {
        var byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for edit in pending where !edit.conflict { byID[edit.meeting.id] = edit.meeting }
        return byID.values.filter { !$0.deleted }.sorted { $0.startAt < $1.startAt }
    }

    mutating func enqueue(_ meeting: AccountMeeting) throws {
        guard !pending.contains(where: { $0.meeting.id == meeting.id }) else {
            throw AccountAgendaError.pending
        }
        if !meeting.deleted {
            guard !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meeting.title.utf16.count <= 512,
                  let start = AccountMeeting.date(meeting.startAt), let end = AccountMeeting.date(meeting.endAt),
                  end > start else { throw AccountAgendaError.invalidMeeting }
        }
        let previous = meetings.first { $0.id == meeting.id }
        pending.append(.init(meeting: meeting, projectChanged: !meeting.deleted && previous?.project != meeting.project))
    }

    mutating func importOccurrence(_ event: UnifiedEvent, project: AccountProject?, into account: AccountConnection) throws -> Bool {
        guard !event.isAllDay, event.status != "cancelled" else { throw AccountAgendaError.invalidMeeting }
        let id = Self.importID(source: event.dedupKey, origin: account.origin, userId: account.credentials.userId)
        if let inFlight = pending.first(where: { $0.meeting.id == id }) {
            if project != nil && inFlight.meeting.project == nil && !inFlight.meeting.deleted { throw AccountAgendaError.pending }
            return false
        }
        var meeting: AccountMeeting
        if let previous = meetings.first(where: { $0.id == id }) {
            // A pre-project copy can gain its confirmed link without overwriting edits from a phone.
            guard !previous.deleted, previous.project == nil, project != nil else { return false }
            meeting = previous
        } else {
            meeting = .draft(id: id, title: event.title, start: event.startTs, end: event.endTs)
        }
        meeting.project = project
        try enqueue(meeting)
        return true
    }

    mutating func reapply(_ edit: AgendaMutation) throws {
        guard let index = pending.firstIndex(where: { $0.id == edit.id && $0.conflict }),
              let current = meetings.first(where: { $0.id == edit.meeting.id && !$0.deleted }) else {
            throw AccountAgendaError.pending
        }
        var revised = pending[index].meeting
        revised.revision = current.revision
        revised.recordings = current.recordings
        if edit.projectChanged != true { revised.project = current.project }
        pending[index] = .init(meeting: revised, projectChanged: edit.projectChanged)
    }

    /// What the conflict banner shows and offers for a parked change.
    func conflict(for edit: AgendaMutation) -> AgendaConflict {
        AgendaConflict(local: edit.meeting, server: meetings.first { $0.id == edit.meeting.id })
    }

    /// Keeps a parked change whose server copy is gone by saving it as a brand-new meeting.
    /// The new meeting has a fresh ID and revision 0 so it cannot resurrect or overwrite the
    /// deleted one; the conflicted change is discarded in the same step.
    @discardableResult
    mutating func saveAsNew(_ edit: AgendaMutation, id: String = UUID().uuidString.lowercased()) throws -> AccountMeeting {
        guard let index = pending.firstIndex(where: { $0.id == edit.id && $0.conflict }),
              conflict(for: pending[index]).canSaveAsNew,
              !meetings.contains(where: { $0.id == id }), !pending.contains(where: { $0.meeting.id == id }) else {
            throw AccountAgendaError.pending
        }
        let local = pending[index].meeting
        let copy = AccountMeeting(id: id, title: local.title, startAt: local.startAt, endAt: local.endAt,
                                  revision: 0, deleted: false, recordings: [], project: local.project)
        var next = self
        next.pending.remove(at: index)
        try next.enqueue(copy)
        self = next
        return copy
    }

    mutating func acknowledge(_ mutation: AgendaMutation, result: AccountMeeting) {
        version = nil
        meetings.removeAll { $0.id == result.id }
        meetings.append(result)
        if mutation.projectChanged == true && mutation.meeting.project?.id != result.project?.id {
            if let i = pending.firstIndex(where: { $0.id == mutation.id }) { pending[i].conflict = true }
        } else { pending.removeAll { $0.id == mutation.id } }
    }

    static func partition(_ origin: URL, _ userId: String) -> String {
        SHA256.hash(data: Data((origin.absoluteString + "\u{0}" + userId).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func file(in root: URL, origin: URL, userId: String) -> URL {
        root.appendingPathComponent(partition(origin, userId)).appendingPathExtension("json")
    }

    static func load(from file: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return .init() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Re-importing a timed occurrence selects the same private copy, including after its deletion.
    static func importID(source: String, origin: URL, userId: String) -> String {
        let namespace = partition(origin, userId)
        var bytes = Array(SHA256.hash(data: Data((namespace + "\u{0}" + source).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return NSUUID(uuidBytes: bytes).uuidString.lowercased()
    }
}

enum AccountAgendaError: LocalizedError {
    case origin, invalidMeeting, pending, session, response(Int, String), invalidResponse, browser

    var errorDescription: String? {
        switch self {
        case .origin: return PublicUICopy.text("Enter the HTTPS origin of your Hall-e account service.", "Introduce el origen HTTPS del servicio de cuentas de Hall-e.")
        case .invalidMeeting: return PublicUICopy.text("Use a title of 1–512 characters and an end after the start.", "Usa un título de 1–512 caracteres y una hora de fin posterior al inicio.")
        case .pending: return PublicUICopy.text("This meeting already has a change waiting to sync.", "Esta reunión ya tiene un cambio pendiente.")
        case .session: return PublicUICopy.text("Sign in again to sync this account.", "Vuelve a iniciar sesión para sincronizar esta cuenta.")
        case .response(let status, let code):
            if code == "link_required" { return PublicUICopy.text("Sign in with the original method, then link this one.", "Inicia sesión con el método original y después vincula este.") }
            if code == "recording_active" { return PublicUICopy.text("This recording is still being processed and cannot be discarded. Sync and try again later.", "Esta grabación aún se está procesando y no se puede descartar. Sincroniza e inténtalo más tarde.") }
            return PublicUICopy.text("The account service returned HTTP \(status) (\(code)).", "El servicio de cuentas devolvió HTTP \(status) (\(code)).")
        case .invalidResponse: return PublicUICopy.text("Unexpected response from the account service.", "Respuesta inesperada del servicio de cuentas.")
        case .browser: return PublicUICopy.text("Google sign-in could not open or timed out.", "No se pudo abrir Google o venció el plazo.")
        }
    }
}

final class AccountRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AccountAPI {
    let origin: URL
    let session: URLSession

    init(origin: URL, session: URLSession = AccountAPI.session) {
        self.origin = origin
        self.session = session
    }

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: AccountRedirectPolicy(), delegateQueue: nil)
    }()

    static func origin(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: value), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.query == nil,
              c.fragment == nil, ["", "/", "/account/v1", "/account/v1/"].contains(c.path) else { throw AccountAgendaError.origin }
        c.host = host.lowercased()
        c.scheme = "https"
        c.path = ""
        if c.port == 443 { c.port = nil }
        guard let origin = c.url else { throw AccountAgendaError.origin }
        return origin
    }

    func request(_ method: String, _ path: String, token: String? = nil,
                 body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> (Int, Data) {
        let url = origin.appendingPathComponent("account/v1").appendingPathComponent(path)
        var request = URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountAgendaError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { var error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw AccountAgendaError.response(http.statusCode, failure?.error ?? "request_failed")
        }
        return (http.statusCode, data)
    }

    func json<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, token: String? = nil,
                            body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> T {
        let (_, data) = try await request(method, path, token: token, body: body, query: query)
        return try JSONDecoder().decode(type, from: data)
    }
}
