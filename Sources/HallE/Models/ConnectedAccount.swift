import Foundation
import GRDB

/// Calendar account metadata. Google uses its email and a Keychain OAuth grant;
/// the macOS calendar bridge uses a reserved local ID and no app-owned credentials.
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
