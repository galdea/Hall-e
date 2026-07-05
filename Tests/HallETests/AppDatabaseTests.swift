import Testing
import Foundation
import GRDB
@testable import HallE

@Suite("AppDatabase")
struct AppDatabaseTests {
    @Test func migratesAndRoundTripsRecords() throws {
        let db = try AppDatabase(inMemory: true)

        let account = ConnectedAccount(
            email: "gabriel@example.com",
            displayName: "Gabriel",
            colorHex: "#3B82F6",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            needsReauth: false,
            lastSyncAt: nil,
            lastSyncError: nil
        )
        try db.dbQueue.write { try account.insert($0) }

        let source = CalendarSource(
            accountEmail: account.email,
            calendarId: account.email,
            summary: "Work",
            colorHex: "#10B981",
            isPrimary: true,
            accessRole: "owner",
            isSelected: true
        )
        try db.dbQueue.write { try source.insert($0) }

        let fetchedAccounts = try db.dbQueue.read { try ConnectedAccount.fetchAll($0) }
        #expect(fetchedAccounts.count == 1)
        #expect(fetchedAccounts.first?.email == "gabriel@example.com")

        let selected = try db.dbQueue.read {
            try CalendarSource.filter(CalendarSource.Columns.isSelected == true).fetchAll($0)
        }
        #expect(selected.count == 1)
    }

    @Test func cascadeDeletesCalendars() throws {
        let db = try AppDatabase(inMemory: true)
        let account = ConnectedAccount(
            email: "a@b.com", displayName: nil, colorHex: "#000000",
            addedAt: Date(), needsReauth: false, lastSyncAt: nil, lastSyncError: nil
        )
        try db.dbQueue.write { try account.insert($0) }
        let source = CalendarSource(
            accountEmail: "a@b.com", calendarId: "cal1", summary: "S",
            colorHex: nil, isPrimary: false, accessRole: "reader", isSelected: false
        )
        try db.dbQueue.write { try source.insert($0) }

        try db.dbQueue.write { _ = try ConnectedAccount.deleteAll($0) }
        let remaining = try db.dbQueue.read { try CalendarSource.fetchCount($0) }
        #expect(remaining == 0)
    }
}
