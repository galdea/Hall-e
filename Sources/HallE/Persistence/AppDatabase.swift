import Foundation
import AppKit
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
            // Keep the UI alive on an in-memory store, but tell the user —
            // otherwise this session's accounts/events silently vanish on quit.
            Task { @MainActor in presentOpenFailure(error) }
            do {
                return try AppDatabase(inMemory: true)
            } catch {
                // SQLite can't even open an in-memory DB: nothing can run.
                fatalError("Unable to open any database: \(error)")
            }
        }
    }()

    @MainActor
    private static func presentOpenFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Hall-e could not open its database"
        alert.informativeText = """
        \(error.localizedDescription)

        Path: \(AppPaths.databaseFile.path)

        Hall-e is running on a temporary in-memory database: nothing you change \
        this session will be saved. Quit and fix (or remove) the database file \
        to restore persistence.
        """
        alert.addButton(withTitle: "Quit Hall-e")
        alert.addButton(withTitle: "Continue Without Saving")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

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

        migrator.registerMigration("v2_vault_index") { db in
            try db.create(table: "vault_document") { t in
                t.primaryKey("path", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("type", .text)
                t.column("project", .text)
                t.column("eventId", .text)
                t.column("contentHash", .text).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("body", .text).notNull().defaults(to: "")
            }
            try db.create(indexOn: "vault_document", columns: ["eventId"])
            try db.create(indexOn: "vault_document", columns: ["project"])
            try db.create(table: "indexed_action_item") { t in
                t.primaryKey("id", .text)
                t.column("notePath", .text).notNull()
                t.column("eventId", .text)
                t.column("task", .text).notNull()
                t.column("owner", .text)
                t.column("dueDate", .text)
                t.column("project", .text)
                t.column("isCompleted", .boolean).notNull().defaults(to: false)
                t.column("confidence", .double)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(indexOn: "indexed_action_item", columns: ["project"])
            try db.create(indexOn: "indexed_action_item", columns: ["isCompleted"])
        }

        migrator.registerMigration("v3_project_knowledge") { db in
            try db.create(table: "project_source") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("location", .text)
                t.column("externalId", .text)
                t.column("includeInAI", .boolean).notNull().defaults(to: true)
                t.column("lastImportedAt", .datetime)
                t.column("lastError", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "project_source", columns: ["projectId"])
            try db.create(indexOn: "project_source", columns: ["kind"])

            try db.create(table: "project_source_document") { t in
                t.primaryKey("id", .text)
                t.column("sourceId", .text).notNull()
                    .references("project_source", onDelete: .cascade)
                t.column("projectId", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("author", .text)
                t.column("occurredAt", .datetime)
                t.column("body", .text).notNull()
                t.column("contentHash", .text).notNull()
                t.column("metadataJSON", .text).notNull().defaults(to: "{}")
                t.column("importedAt", .datetime).notNull()
            }
            try db.create(indexOn: "project_source_document", columns: ["projectId", "occurredAt"])
            try db.create(indexOn: "project_source_document", columns: ["sourceId"])

            try db.create(table: "project_snapshot") { t in
                t.primaryKey("projectId", .text)
                t.column("summary", .text).notNull()
                t.column("status", .text).notNull()
                t.column("health", .text).notNull()
                t.column("goalsJSON", .text).notNull().defaults(to: "[]")
                t.column("decisionsJSON", .text).notNull().defaults(to: "[]")
                t.column("blockersJSON", .text).notNull().defaults(to: "[]")
                t.column("risksJSON", .text).notNull().defaults(to: "[]")
                t.column("nextStepsJSON", .text).notNull().defaults(to: "[]")
                t.column("openQuestionsJSON", .text).notNull().defaults(to: "[]")
                t.column("agendaJSON", .text).notNull().defaults(to: "[]")
                t.column("citationsJSON", .text).notNull().defaults(to: "[]")
                t.column("generatedAt", .datetime).notNull()
                t.column("sourceRevision", .text).notNull()
                t.column("confidence", .double)
                t.column("providerName", .text).notNull()
            }

            try db.create(table: "project_assistant_message") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                t.column("role", .text).notNull()
                t.column("body", .text).notNull()
                t.column("citationsJSON", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "project_assistant_message", columns: ["projectId", "createdAt"])
        }

        migrator.registerMigration("v4_event_project_assignments") { db in
            try db.create(table: "event_project_assignment") { t in
                t.primaryKey("dedupKey", .text)
                t.column("projectId", .text)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v5_local_capture_events") { db in
            // Separate from unified_event: calendar sync only rebuilds its own
            // derived rows, and therefore can never create or mutate Google
            // events for a Hall-e-only call capture.
            try db.create(table: "local_capture_event") { t in
                t.primaryKey("id", .text)
                t.column("identityKey", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("title", .text).notNull()
                t.column("startTs", .datetime).notNull()
                t.column("endTs", .datetime).notNull()
                t.column("notePath", .text)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "local_capture_event", columns: ["startTs"])
            try db.create(indexOn: "local_capture_event", columns: ["identityKey"])
        }

        migrator.registerMigration("v6_recurring_project_assignments") { db in
            try db.create(table: "recurring_project_assignment") { t in
                t.column("seriesId", .text).notNull()
                t.column("effectiveFrom", .datetime).notNull()
                t.column("projectId", .text)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["seriesId", "effectiveFrom"])
            }
        }

        return migrator
    }
}
