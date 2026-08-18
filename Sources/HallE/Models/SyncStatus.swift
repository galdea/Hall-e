import Foundation

struct SyncStatus: Equatable {
    var isSyncing = false
    var lastSyncAt: Date?
    var error: String?
    var accountErrors: [String: String] = [:]
}
