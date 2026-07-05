import Foundation
import GRDB

/// Ledger row that prevents duplicate meeting notifications across re-syncs.
/// Keyed by (dedupKey, startTs) so a rescheduled meeting re-notifies.
struct NotificationRecord: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var dedupKey: String
    var startTs: Date
    var scheduledFor: Date
    var status: String        // pending | delivered | cancelled | skipped
    var deliveredAt: Date?
    var snoozedUntil: Date?

    var id: String { "\(dedupKey)\u{1F}\(startTs.timeIntervalSince1970)" }

    static let databaseTableName = "notification_record"

    enum Columns {
        static let dedupKey = Column(CodingKeys.dedupKey)
        static let startTs = Column(CodingKeys.startTs)
        static let status = Column(CodingKeys.status)
    }
}

enum NotificationStatus: String {
    case pending, delivered, cancelled, skipped
}
