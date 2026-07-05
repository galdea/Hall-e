import Foundation
import GRDB

/// Owns the GRDB connection and schema. The `DatabaseQueue` is the app's
/// serialization boundary for all persisted state; `ValueObservation` drives
/// the agenda UI reactively from background sync writes.
final class AppDatabase: Sendable {
    let dbQueue: DatabaseQueue

    /// Shared app instance, backed by the on-disk sqlite file.
    static let shared: AppDatabase = {
        do {
            return try AppDatabase(path: AppPaths.databaseFile.path)
        } catch {
            Log.db.error("Failed to open database: \(error, privacy: .public)")
            // A broken DB should not crash the whole assistant; fall back to
            // an in-memory store so the UI still runs.
            return try! AppDatabase(inMemory: true)
        }
    }()

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(dbQueue)
        Log.db.info("Database opened at \(path, privacy: .public)")
    }

    init(inMemory: Bool) throws {
        dbQueue = try DatabaseQueue()
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "connected_account") { t in
                t.primaryKey("email", .text)
                t.column("displayName", .text)
                t.column("colorHex", .text).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("needsReauth", .boolean).notNull().defaults(to: false)
                t.column("lastSyncAt", .datetime)
                t.column("lastSyncError", .text)
            }

            try db.create(table: "calendar_source") { t in
                t.column("accountEmail", .text).notNull()
                    .references("connected_account", column: "email", onDelete: .cascade)
                t.column("calendarId", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("colorHex", .text)
                t.column("isPrimary", .boolean).notNull().defaults(to: false)
                t.column("accessRole", .text).notNull().defaults(to: "reader")
                t.column("isSelected", .boolean).notNull().defaults(to: false)
                t.primaryKey(["accountEmail", "calendarId"])
            }

            try db.create(table: "calendar_event") { t in
                t.column("accountEmail", .text).notNull()
                t.column("calendarId", .text).notNull()
                t.column("eventId", .text).notNull()
                t.column("iCalUID", .text)
                t.column("title", .text)
                t.column("startTs", .datetime).notNull()
                t.column("endTs", .datetime).notNull()
                t.column("isAllDay", .boolean).notNull().defaults(to: false)
                t.column("status", .text).notNull().defaults(to: "confirmed")
                t.column("myResponseStatus", .text)
                t.column("organizerEmail", .text)
                t.column("attendeesJSON", .text)
                t.column("meetingURL", .text)
                t.column("location", .text)
                t.column("descriptionText", .text)
                t.column("htmlLink", .text)
                t.column("originalStartTs", .datetime)
                t.column("etag", .text)
                t.column("updatedAt", .datetime)
                t.column("fetchedAt", .datetime).notNull()
                t.primaryKey(["accountEmail", "calendarId", "eventId"])
            }
            try db.create(indexOn: "calendar_event", columns: ["startTs"])
            try db.create(indexOn: "calendar_event", columns: ["iCalUID"])

            try db.create(table: "unified_event") { t in
                t.primaryKey("dedupKey", .text)
                t.column("title", .text).notNull()
                t.column("startTs", .datetime).notNull()
                t.column("endTs", .datetime).notNull()
                t.column("isAllDay", .boolean).notNull().defaults(to: false)
                t.column("status", .text).notNull().defaults(to: "confirmed")
                t.column("effectiveResponse", .text)
                t.column("meetingURL", .text)
                t.column("location", .text)
                t.column("descriptionText", .text)
                t.column("htmlLink", .text)
                t.column("organizerEmail", .text)
                t.column("attendeesJSON", .text)
                t.column("iCalUID", .text)
                t.column("winnerAccountEmail", .text).notNull()
                t.column("projectId", .text)
                t.column("projectConfidence", .double)
                t.column("sourcesJSON", .text).notNull().defaults(to: "[]")
            }
            try db.create(indexOn: "unified_event", columns: ["startTs"])

            try db.create(table: "notification_record") { t in
                t.column("dedupKey", .text).notNull()
                t.column("startTs", .datetime).notNull()
                t.column("scheduledFor", .datetime).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("deliveredAt", .datetime)
                t.column("snoozedUntil", .datetime)
                t.primaryKey(["dedupKey", "startTs"])
            }
        }

        return migrator
    }
}
