import Foundation
import GRDB

/// A connected Google account (one OAuth grant). Refresh token lives in Keychain,
/// keyed by `email`; this row holds only non-secret metadata.
struct ConnectedAccount: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var email: String
    var displayName: String?
    var colorHex: String
    var addedAt: Date
    var needsReauth: Bool
    var lastSyncAt: Date?
    var lastSyncError: String?

    var id: String { email }

    static let databaseTableName = "connected_account"

    enum Columns {
        static let email = Column(CodingKeys.email)
        static let needsReauth = Column(CodingKeys.needsReauth)
        static let lastSyncAt = Column(CodingKeys.lastSyncAt)
    }
}
