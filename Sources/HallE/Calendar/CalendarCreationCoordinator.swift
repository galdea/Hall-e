import Foundation
import GRDB

protocol CalendarEventWriting: Sendable {
    var supportsIdempotentRetry: Bool { get }
    func create(_ draft: CalendarEventDraft, in target: CalendarWriteTarget) async throws -> CalendarEvent
}

struct CalendarCreationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "calendar_creation"
    var requestID: String
    var draftJSON: String
    var targetJSON: String
    var state: String
    var resultJSON: String?
    var updatedAt: Date
}

/// Durable request identity protects retries and double clicks, including across app restarts.
actor CalendarCreationCoordinator {
    static let shared = CalendarCreationCoordinator(database: AppDatabase.shared.dbQueue, writer: ConnectedCalendarWriter())
    private let database: DatabaseQueue
    private let writer: any CalendarEventWriting
    private var pending: [UUID: ActiveSave] = [:]
    init(database: DatabaseQueue, writer: any CalendarEventWriting) { self.database = database; self.writer = writer }

    func save(_ draft: CalendarEventDraft, target: CalendarWriteTarget) async throws -> CalendarEvent {
        let validated = try draft.validated()
        guard target.writable else { throw CalendarCreationError.permission }
        if let active = pending[draft.requestID] {
            guard active.draft == validated, active.target == target else { throw CalendarCreationError.changedRequest }
            return try await active.task.value
        }
        let task = Task { try await self.performSave(validated, target: target) }
        pending[draft.requestID] = ActiveSave(draft: validated, target: target, task: task)
        defer { pending[draft.requestID] = nil }
        return try await task.value
    }

    private struct ActiveSave {
        let draft: CalendarEventDraft
        let target: CalendarWriteTarget
        let task: Task<CalendarEvent, Error>
    }

    private func performSave(_ draft: CalendarEventDraft, target: CalendarWriteTarget) async throws -> CalendarEvent {
        let validated = draft
        let draftJSON = String(decoding: try JSONEncoder().encode(validated), as: UTF8.self)
        let targetJSON = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
        let previous = try await database.read { try CalendarCreationRecord.fetchOne($0, key: draft.requestID.uuidString) }
        if let previous {
            guard try JSONDecoder().decode(CalendarEventDraft.self, from: Data(previous.draftJSON.utf8)) == validated,
                  try JSONDecoder().decode(CalendarWriteTarget.self, from: Data(previous.targetJSON.utf8)) == target else {
                throw CalendarCreationError.changedRequest
            }
            if let result = previous.resultJSON {
                return try JSONDecoder().decode(CalendarEvent.self, from: Data(result.utf8))
            }
            if previous.state != "rejected" && !writer.supportsIdempotentRetry && !target.isMac {
                throw CalendarCreationError.uncertain
            }
            if previous.state != "rejected" && target.isMac { throw CalendarCreationError.uncertain }
        }
        let record = CalendarCreationRecord(requestID: draft.requestID.uuidString, draftJSON: draftJSON,
            targetJSON: targetJSON, state: "pending", resultJSON: nil, updatedAt: Date())
        // save() registered the in-flight task before its first suspension.
        try await database.write { try record.save($0) }
        let writer = writer, database = database
        let task = Task<CalendarEvent, Error> {
            do {
                let event = try await writer.create(validated, in: target)
                let result = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
                try await database.write { db in
                    var completed = record; completed.state = "saved"; completed.resultJSON = result; completed.updatedAt = Date()
                    try completed.update(db)
                    // Never resurrect a removed account or enable a hidden calendar implicitly.
                    if let source = try CalendarSource.fetchOne(db, key: ["accountEmail": target.accountEmail, "calendarId": target.calendarID]), source.isSelected {
                        try event.save(db)
                    }
                }
                return event
            } catch {
                let definitelyRejected: Bool
                if let creationError = error as? CalendarCreationError {
                    switch creationError {
                    case .permission, .validation, .rejected: definitelyRejected = true
                    default: definitelyRejected = false
                    }
                } else if error is MacCalendarProvider.CalendarAccessError { definitelyRejected = true }
                else { definitelyRejected = false }
                try? await database.write { db in
                    try db.execute(sql: "UPDATE calendar_creation SET state = ?, updatedAt = ? WHERE requestID = ?",
                                   arguments: [definitelyRejected ? "rejected" : "uncertain", Date(), record.requestID])
                }
                throw error
            }
        }
        return try await task.value
    }
}

struct ConnectedCalendarWriter: CalendarEventWriting {
    var supportsIdempotentRetry: Bool { true } // Google uses a client-supplied ID; Mac retries are blocked by the ledger.
    func create(_ draft: CalendarEventDraft, in target: CalendarWriteTarget) async throws -> CalendarEvent {
        let source = try await AppDatabase.shared.dbQueue.read {
            try CalendarSource.fetchOne($0, key: ["accountEmail": target.accountEmail, "calendarId": target.calendarID])
        }
        guard let source, CalendarWriteTarget(source).writable else { throw CalendarCreationError.permission }
        if target.isMac { return try await MacCalendarProvider.shared.create(draft, calendarID: target.calendarID) }
        let account = try await AppDatabase.shared.dbQueue.read { try ConnectedAccount.fetchOne($0, key: target.accountEmail) }
        guard (account?.grantedScopes ?? "").split(separator: " ").contains(Substring(GoogleOAuthClient.writeScope)) else {
            throw CalendarCreationError.permission
        }
        let writer = GoogleCalendarWriter(accessToken: { try await TokenStore.shared.accessToken(for: target.accountEmail) },
            invalidateToken: { await TokenStore.shared.invalidate(target.accountEmail) })
        return try await writer.create(draft, in: target)
    }
}

/// Transport is injectable; tests never need OAuth, Keychain, or an external calendar.
struct GoogleCalendarWriter: CalendarEventWriting {
    var supportsIdempotentRetry: Bool { true }
    var accessToken: @Sendable () async throws -> String
    var invalidateToken: @Sendable () async -> Void
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }
    func create(_ draft: CalendarEventDraft, in target: CalendarWriteTarget) async throws -> CalendarEvent {
        let payload = try draft.googlePayload()
        let base = "https://www.googleapis.com/calendar/v3/calendars/\(Self.segment(target.calendarID))/events"
        var request = URLRequest(url: URL(string: base)!)
        request.httpMethod = "POST"; request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.timeoutInterval = 30
        let (data, response) = try await send(request)
        var event: GEvent
        if response.statusCode == 409 {
            var read = URLRequest(url: URL(string: base + "/" + draft.providerID)!)
            read.timeoutInterval = 30
            let (existing, status) = try await send(read)
            guard status.statusCode == 200 else { throw CalendarCreationError.uncertain }
            event = try JSONDecoder().decode(GEvent.self, from: existing)
            if event.start?.date != nil && event.start?.timeZone == nil { event.start?.timeZone = draft.timeZoneID }
            if event.end?.date != nil && event.end?.timeZone == nil { event.end?.timeZone = draft.timeZoneID }
            // A collision must match all user-authored content before being accepted.
            guard event.id == draft.providerID, event.summary == draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                  EventMapper.parseDateTime(event.start)?.date == (try draft.validated()).start,
                  EventMapper.parseDateTime(event.end)?.date == (try draft.validated()).end,
                  (event.description ?? "") == draft.notes, (event.recurrence ?? []) == draft.rules,
                  event.status != "cancelled" else { throw CalendarCreationError.uncertain }
        } else {
            guard response.statusCode == 200 || response.statusCode == 201 else {
                if [400, 401, 403, 404, 429].contains(response.statusCode) { throw CalendarCreationError.rejected(response.statusCode) }
                throw CalendarCreationError.uncertain
            }
            event = try JSONDecoder().decode(GEvent.self, from: data)
        }
        if event.start?.date != nil && event.start?.timeZone == nil { event.start?.timeZone = draft.timeZoneID }
        if event.end?.date != nil && event.end?.timeZone == nil { event.end?.timeZone = draft.timeZoneID }
        guard let mapped = EventMapper.map(event, accountEmail: target.accountEmail, calendarId: target.calendarID, fetchedAt: Date()) else {
            throw CalendarCreationError.uncertain
        }
        return mapped
    }
    private func send(_ request: URLRequest, retry: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var authorized = request
        authorized.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(authorized)
        guard let response = response as? HTTPURLResponse else { throw CalendarCreationError.uncertain }
        if response.statusCode == 401 && retry {
            await invalidateToken()
            return try await send(request, retry: false)
        }
        return (data, response)
    }
}
