import Foundation
import CryptoKit

/// Collapses `CalendarEvent` rows (across accounts/calendars) into deduplicated
/// `UnifiedEvent`s. Pure and deterministic — the core of cross-account merging.
enum EventDeduplicator {
    /// Response status ranking; higher is "better" (drives winner + effective response).
    private static func responseRank(_ s: String?) -> Int {
        switch s {
        case "accepted": 4
        case "tentative": 3
        case "needsAction", nil: 2
        case "declined": 1
        default: 2
        }
    }

    static func dedupKey(for e: CalendarEvent) -> String {
        if let uid = e.iCalUID, !uid.isEmpty {
            // Recurring instances share one iCalUID, so include the instance start.
            let instant = e.originalStartTs ?? e.startTs
            return "ical:\(uid)@\(Int(instant.timeIntervalSince1970))"
        }
        let norm = (e.title ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(norm)|\(Int(e.startTs.timeIntervalSince1970))|\(Int(e.endTs.timeIntervalSince1970))|\(e.meetingURL ?? e.organizerEmail ?? "")"
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        return "fz:\(hash.prefix(16))"
    }

    /// Deduplicate. `primaryEmail` and `colorFor` influence winner choice and
    /// per-source color dots.
    static func deduplicate(_ events: [CalendarEvent],
                            primaryEmail: String?,
                            colorFor: (String, String) -> String?) -> [UnifiedEvent] {
        var buckets: [String: [CalendarEvent]] = [:]
        for e in events {
            buckets[dedupKey(for: e), default: []].append(e)
        }

        return buckets.map { key, group in
            let winner = chooseWinner(group, primaryEmail: primaryEmail)

            // Display status: cancelled wins only if no confirmed copy exists.
            let anyConfirmed = group.contains { $0.status == "confirmed" }
            let anyCancelled = group.contains { $0.status == "cancelled" }
            let displayStatus = (anyCancelled && !anyConfirmed) ? "cancelled" : winner.status

            // Effective response = best across sources.
            let effective = group.map { $0.myResponseStatus }
                .max { responseRank($0) < responseRank($1) } ?? winner.myResponseStatus

            // meetingURL falls back to any source that has one.
            let url = winner.meetingURL ?? group.compactMap { $0.meetingURL }.first

            let sources = group.map { e in
                EventSource(accountEmail: e.accountEmail, calendarId: e.calendarId,
                            eventId: e.eventId, responseStatus: e.myResponseStatus,
                            colorHex: colorFor(e.accountEmail, e.calendarId))
            }
            let sourcesJSON = (try? JSONEncoder().encode(sources)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"

            return UnifiedEvent(
                dedupKey: key,
                title: winner.title ?? "(no title)",
                startTs: winner.startTs,
                endTs: winner.endTs,
                isAllDay: winner.isAllDay,
                status: displayStatus,
                effectiveResponse: effective,
                meetingURL: url,
                location: winner.location,
                descriptionText: winner.descriptionText,
                htmlLink: winner.htmlLink,
                organizerEmail: winner.organizerEmail,
                attendeesJSON: winner.attendeesJSON,
                iCalUID: winner.iCalUID,
                winnerAccountEmail: winner.accountEmail,
                projectId: nil,
                projectConfidence: nil,
                sourcesJSON: sourcesJSON
            )
        }
        .sorted { $0.startTs < $1.startTs }
    }

    private static func chooseWinner(_ group: [CalendarEvent], primaryEmail: String?) -> CalendarEvent {
        group.sorted { a, b in
            // 1. best own response status
            let ra = responseRank(a.myResponseStatus), rb = responseRank(b.myResponseStatus)
            if ra != rb { return ra > rb }
            // 2. primary account preference
            let ap = a.accountEmail == primaryEmail, bp = b.accountEmail == primaryEmail
            if ap != bp { return ap }
            // 3. lexicographic email (deterministic tie-break)
            return a.accountEmail < b.accountEmail
        }.first!
    }
}
