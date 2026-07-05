import Foundation

/// Converts Google API `GEvent` DTOs into cached `CalendarEvent` rows.
/// Pure and deterministic (except `fetchedAt`, injected by the caller).
enum EventMapper {
    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let rfc3339NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDateTime(_ dt: GEventDateTime?) -> (date: Date, isAllDay: Bool)? {
        guard let dt else { return nil }
        if let s = dt.dateTime {
            if let d = rfc3339.date(from: s) ?? rfc3339NoFrac.date(from: s) {
                return (d, false)
            }
        }
        if let s = dt.date {
            // All-day: interpret yyyy-MM-dd at local midnight.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            let parts = s.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 {
                var comps = DateComponents()
                comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
                if let d = cal.date(from: comps) { return (d, true) }
            }
        }
        return nil
    }

    static func meetingURL(for e: GEvent) -> String? {
        if let h = e.hangoutLink, !h.isEmpty { return h }
        if let video = e.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri {
            return video
        }
        // Fall back to a known-provider URL in location or description.
        for text in [e.location, e.description].compactMap({ $0 }) {
            if let url = firstMeetingURL(in: text) { return url }
        }
        return nil
    }

    static func firstMeetingURL(in text: String) -> String? {
        let patterns = ["zoom.us/j/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/",
                        "whereby.com/", "meet.jit.si/"]
        // Extract URL-ish tokens and match against known providers.
        let tokens = text.split { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "<" || $0 == ">" }
        for token in tokens {
            let s = String(token)
            if s.contains("http"), patterns.contains(where: { s.contains($0) }) {
                return s.trimmingCharacters(in: CharacterSet(charactersIn: "()[]\"',"))
            }
        }
        return nil
    }

    /// Map a single event; returns nil if it has no usable start/end.
    static func map(_ e: GEvent, accountEmail: String, calendarId: String, fetchedAt: Date) -> CalendarEvent? {
        guard let start = parseDateTime(e.start), let end = parseDateTime(e.end) else { return nil }

        let attendees: [EventAttendee] = (e.attendees ?? []).map {
            EventAttendee(name: $0.displayName, email: $0.email,
                          responseStatus: $0.responseStatus,
                          isSelf: $0.isSelf ?? false, isOrganizer: $0.organizer ?? false)
        }
        let myResponse = (e.attendees ?? []).first(where: { $0.isSelf == true })?.responseStatus
        let attendeesJSON = (try? JSONEncoder().encode(attendees)).map { String(decoding: $0, as: UTF8.self) }
        let originalStart = parseDateTime(e.originalStartTime)?.date

        return CalendarEvent(
            accountEmail: accountEmail,
            calendarId: calendarId,
            eventId: e.id,
            iCalUID: e.iCalUID,
            title: e.summary,
            startTs: start.date,
            endTs: end.date,
            isAllDay: start.isAllDay,
            status: e.status ?? "confirmed",
            myResponseStatus: myResponse,
            organizerEmail: e.organizer?.email,
            attendeesJSON: attendeesJSON,
            meetingURL: meetingURL(for: e),
            location: e.location,
            descriptionText: e.description,
            htmlLink: e.htmlLink,
            originalStartTs: originalStart,
            etag: e.etag,
            updatedAt: e.updated.flatMap { rfc3339.date(from: $0) ?? rfc3339NoFrac.date(from: $0) },
            fetchedAt: fetchedAt
        )
    }
}
