import Foundation
import GRDB

/// Inserts sample data for headless UI verification. Only runs when
/// HALLE_DEBUG_FIXTURES=1. Never used in normal operation.
enum DebugFixtures {
    static func loadIfRequested() {
        guard ProcessInfo.processInfo.environment["HALLE_DEBUG_FIXTURES"] == "1" else { return }
        do { try load() } catch { Log.app.error("fixtures failed: \(error, privacy: .public)") }
    }

    private static func load() throws {
        let db = AppDatabase.shared.dbQueue
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int) -> Date { cal.date(byAdding: DateComponents(hour: h, minute: m), to: today)! }

        let accounts = [
            ConnectedAccount(email: "maximiliano@yom.ai", displayName: "Max", colorHex: "#3B82F6",
                             addedAt: Date(), needsReauth: false, lastSyncAt: Date(), lastSyncError: nil),
            ConnectedAccount(email: "gabriel@getaccurate.cl", displayName: "Gabriel", colorHex: "#10B981",
                             addedAt: Date(), needsReauth: false, lastSyncAt: Date(), lastSyncError: nil),
        ]

        func source(_ account: String, _ cal: String, _ eventId: String, _ color: String) -> EventSource {
            EventSource(accountEmail: account, calendarId: cal, eventId: eventId, responseStatus: "accepted", colorHex: color)
        }
        func encode(_ s: [EventSource]) -> String { String(decoding: try! JSONEncoder().encode(s), as: UTF8.self) }

        let now = Date()
        let events: [UnifiedEvent] = [
            UnifiedEvent(dedupKey: "fx-allday", title: "Q3 Planning Offsite", startTs: today, endTs: at(23, 59),
                         isAllDay: true, status: "confirmed", effectiveResponse: "accepted", meetingURL: nil,
                         location: nil, descriptionText: nil, htmlLink: "https://calendar.google.com/x",
                         organizerEmail: nil, attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: accounts[0].email,
                         projectId: "Accurate", projectConfidence: 0.9,
                         sourcesJSON: encode([source(accounts[0].email, "c", "1", "#3B82F6")])),
            UnifiedEvent(dedupKey: "fx-now", title: "Director Dashboard Review",
                         startTs: now.addingTimeInterval(-600), endTs: now.addingTimeInterval(1800),
                         isAllDay: false, status: "confirmed", effectiveResponse: "accepted",
                         meetingURL: "https://meet.google.com/abc-defg-hij", location: nil, descriptionText: nil,
                         htmlLink: "https://calendar.google.com/y", organizerEmail: "ana@getaccurate.cl",
                         attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: accounts[1].email,
                         projectId: "Accurate", projectConfidence: 0.95,
                         sourcesJSON: encode([source(accounts[0].email, "c", "2", "#3B82F6"),
                                              source(accounts[1].email, "c", "3", "#10B981")])),
            UnifiedEvent(dedupKey: "fx-next", title: "Cazadescuentos — ingesta bancos",
                         startTs: at(15, 0), endTs: at(15, 45), isAllDay: false, status: "confirmed",
                         effectiveResponse: "tentative", meetingURL: "https://zoom.us/j/123", location: nil,
                         descriptionText: nil, htmlLink: "https://calendar.google.com/z", organizerEmail: nil,
                         attendeesJSON: nil, iCalUID: nil, winnerAccountEmail: accounts[0].email,
                         projectId: "Cazadescuentos", projectConfidence: 0.82,
                         sourcesJSON: encode([source(accounts[0].email, "c", "4", "#3B82F6")])),
            UnifiedEvent(dedupKey: "fx-later", title: "Viña Cousiño — landing review",
                         startTs: at(17, 30), endTs: at(18, 0), isAllDay: false, status: "confirmed",
                         effectiveResponse: "accepted", meetingURL: nil, location: "Oficina",
                         descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
                         iCalUID: nil, winnerAccountEmail: accounts[0].email, projectId: "Viña Cousiño Macul",
                         projectConfidence: 0.88,
                         sourcesJSON: encode([source(accounts[0].email, "c", "5", "#3B82F6")])),
        ]

        try db.write { db in
            for var a in accounts { try a.save(db) }
            for var e in events { try e.save(db) }
        }
    }
}
