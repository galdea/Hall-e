import Foundation
import CryptoKit

struct AccountRecording: Codable, Equatable, Identifiable {
    var id: String
    var status: String
    var transcript: String?
    var source: String? = nil
}

struct AccountMeeting: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var startAt: String
    var endAt: String
    var revision: Int
    var deleted: Bool
    var recordings: [AccountRecording]

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
    var id: String { mutationId }
    var body: [String: Any] {
        ["title": meeting.title, "startAt": meeting.startAt, "endAt": meeting.endAt, "deleted": meeting.deleted,
         "baseRevision": meeting.revision, "mutationId": mutationId]
    }
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
        pending.append(.init(meeting: meeting))
    }

    mutating func reapply(_ edit: AgendaMutation) throws {
        guard let index = pending.firstIndex(where: { $0.id == edit.id && $0.conflict }),
              let current = meetings.first(where: { $0.id == edit.meeting.id && !$0.deleted }) else {
            throw AccountAgendaError.pending
        }
        var revised = pending[index].meeting
        revised.revision = current.revision
        revised.recordings = current.recordings
        pending[index] = .init(meeting: revised)
    }

    mutating func acknowledge(_ mutation: AgendaMutation, result: AccountMeeting) {
        version = nil
        meetings.removeAll { $0.id == result.id }
        meetings.append(result)
        pending.removeAll { $0.id == mutation.id }
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
