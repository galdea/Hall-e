import Foundation

/// Provider-expanded occurrences are authoritative; this view model never expands RRULEs.
enum CalendarPresentation {
    static func days(in month: Date, calendar: Calendar) -> [Date] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        guard let first = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    static func events(on day: Date, events: [UnifiedEvent], calendar: Calendar) -> [UnifiedEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter {
            $0.status != "cancelled" && $0.effectiveResponse != "declined"
                && $0.startTs < end && $0.endTs > start
        }.sorted { a, b in a.startTs == b.startTs ? a.dedupKey < b.dedupKey : a.startTs < b.startTs }
    }

    static func routine(_ rulesJSON: String?) -> Bool {
        guard let data = rulesJSON?.data(using: .utf8),
              let rules = try? JSONDecoder().decode([String].self, from: data) else { return false }
        return rules.contains { rule in
            guard rule.uppercased().hasPrefix("RRULE:") else { return false }
            let fields = rule.uppercased().dropFirst(6).split(separator: ";")
            return fields.contains("FREQ=DAILY") || fields.contains("FREQ=WEEKLY")
        }
    }
}

struct CalendarWriteTarget: Codable, Hashable, Identifiable {
    var accountEmail: String
    var calendarID: String
    var name: String
    var accessRole: String
    var isSelected: Bool
    var id: String { accountEmail + "\u{1F}" + calendarID }
    var isMac: Bool { accountEmail == "macos-calendars" }
    var writable: Bool { accessRole == "owner" || accessRole == "writer" }
    init(_ source: CalendarSource) {
        accountEmail = source.accountEmail; calendarID = source.calendarId
        name = source.summary; accessRole = source.accessRole; isSelected = source.isSelected
    }
}

struct CalendarEventDraft: Codable, Equatable {
    enum Repetition: String, Codable, CaseIterable { case none, daily, weekly }
    var requestID = UUID()
    var title = ""
    var start: Date
    var end: Date
    var timeZoneID: String = TimeZone.current.identifier
    var allDay = false
    var repetition: Repetition = .none
    var notes = ""

    var providerID: String { requestID.uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    var rules: [String] { repetition == .none ? [] : ["RRULE:FREQ=\(repetition.rawValue.uppercased())"] }

    func validated() throws -> CalendarEventDraft {
        var draft = self
        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.title.isEmpty else { throw CalendarCreationError.validation("Enter an event title.") }
        guard let zone = TimeZone(identifier: timeZoneID) else {
            throw CalendarCreationError.validation("Choose a valid IANA time zone, such as America/Santiago.")
        }
        draft.start = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970))
        draft.end = Date(timeIntervalSince1970: floor(end.timeIntervalSince1970))
        if allDay {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            draft.start = calendar.startOfDay(for: start)
            draft.end = calendar.startOfDay(for: end)
        }
        guard draft.end > draft.start else {
            throw CalendarCreationError.validation(allDay ? "The all-day end date is exclusive and must follow the start date." : "The end must be after the start.")
        }
        return draft
    }

    func googlePayload() throws -> Data {
        let draft = try validated()
        let zone = TimeZone(identifier: draft.timeZoneID)!
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = zone
        formatter.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        let key = allDay ? "date" : "dateTime"
        var payload: [String: Any] = [
            "id": providerID, "summary": draft.title,
            "start": [key: formatter.string(from: draft.start), "timeZone": draft.timeZoneID],
            "end": [key: formatter.string(from: draft.end), "timeZone": draft.timeZoneID],
        ]
        if !draft.notes.isEmpty { payload["description"] = draft.notes }
        if !draft.rules.isEmpty { payload["recurrence"] = draft.rules }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

enum CalendarCreationError: LocalizedError {
    case validation(String), permission, uncertain, changedRequest, transport(String), rejected(Int)
    var errorDescription: String? {
        switch self {
        case .validation(let message), .transport(let message): message
        case .permission: "This calendar needs event-writing permission. Enable writing explicitly, or select another calendar."
        case .uncertain: "The save outcome is unknown. Check the calendar before trying again; this request will not be duplicated automatically."
        case .rejected(let status): "The calendar rejected the save (HTTP \(status)). Check calendar access or wait, then retry this same request."
        case .changedRequest: "This saved request has changed. Start a new event instead."
        }
    }
}
