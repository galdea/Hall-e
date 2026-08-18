import Foundation
import GRDB

/// Orchestrates connecting/removing Google accounts:
/// interactive OAuth → identify the account via its primary calendar →
/// persist account + calendar sources + refresh token (Keychain).
@MainActor
enum GoogleAccountManager {
    private static let palette = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6"]

    enum AccountError: Error, LocalizedError {
        case noRefreshToken
        case cannotIdentifyAccount
        var errorDescription: String? {
            switch self {
            case .noRefreshToken: "Google did not return a refresh token. Remove the app's access in your Google account and reconnect."
            case .cannotIdentifyAccount: "Could not read the account's primary calendar to identify it."
            }
        }
    }

    /// Runs the full add-account flow. Returns the connected account's email.
    @discardableResult
    static func addAccount() async throws -> String {
        guard let config = GoogleClientConfig.load() else {
            throw GoogleClientConfig.ConfigError.notImported
        }
        let client = GoogleOAuthClient(config: config)
        let tokens = try await client.authorize()
        guard let refresh = tokens.refreshToken else { throw AccountError.noRefreshToken }

        // Identify the account: prime the token cache, then read calendarList and
        // find the primary calendar (its id is the account email).
        let email = try await identifyAndPersistCalendars(accessToken: tokens.accessToken,
                                                          expiresIn: tokens.expiresIn)
        // Persist the refresh token now that we know the email.
        try KeychainStore.set(refresh, account: KeychainStore.googleRefreshAccount(email: email))
        await TokenStore.shared.seed(email: email, accessToken: tokens.accessToken, expiresIn: tokens.expiresIn)

        try await persistAccount(email: email)
        Log.oauth.info("Connected Google account \(email, privacy: .private)")
        return email
    }

    static func removeAccount(_ email: String) {
        KeychainStore.delete(account: KeychainStore.googleRefreshAccount(email: email))
        Task {
            try? await AppDatabase.shared.dbQueue.write { db in
                _ = try ConnectedAccount.deleteOne(db, key: email)
                // calendar_source rows cascade via FK.
                try CalendarEvent.filter(CalendarEvent.Columns.accountEmail == email).deleteAll(db)
            }
            await TokenStore.shared.invalidate(email)
            await SyncCoordinator.shared.rebuildAfterSourceChange()
        }
    }

    static func toggleCalendar(accountEmail: String, calendarId: String, selected: Bool) {
        Task {
            try? await AppDatabase.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE calendar_source SET isSelected = ? WHERE accountEmail = ? AND calendarId = ?",
                               arguments: [selected, accountEmail, calendarId])
                if !selected {
                    try CalendarEvent
                        .filter(CalendarEvent.Columns.accountEmail == accountEmail
                                && CalendarEvent.Columns.calendarId == calendarId)
                        .deleteAll(db)
                }
            }
            await SyncCoordinator.shared.rebuildAfterSourceChange()
        }
    }

    // MARK: - Helpers

    /// Uses a one-off access token to list calendars and returns the primary's id (email).
    private static func identifyAndPersistCalendars(accessToken: String, expiresIn: Int?) async throws -> String {
        // Temporarily seed under a placeholder so the API client can fetch.
        let placeholder = "pending-\(UUID().uuidString)"
        await TokenStore.shared.seed(email: placeholder, accessToken: accessToken, expiresIn: expiresIn)
        let api = GoogleCalendarAPI(email: placeholder, tokenStore: .shared)
        let entries = try await api.calendarList()
        await TokenStore.shared.invalidate(placeholder)

        guard let primary = entries.first(where: { $0.primary == true })?.id ?? entries.first?.id else {
            throw AccountError.cannotIdentifyAccount
        }
        // Defer persisting calendars until after we persist the account row (FK),
        // so stash them keyed by the resolved email.
        pendingCalendars[primary] = entries
        return primary
    }

    private static var pendingCalendars: [String: [CalendarListEntry]] = [:]

    private static func persistAccount(email: String) async throws {
        // Always drop the stash, even when a write below throws — otherwise a
        // failed connect leaks the entry until the next successful one.
        defer { pendingCalendars[email] = nil }
        let existing = try await AppDatabase.shared.dbQueue.read { try ConnectedAccount.fetchCount($0) }
        let color = palette[existing % palette.count]
        let calendars = pendingCalendars[email] ?? []
        try await AppDatabase.shared.dbQueue.write { db in
            var account = try ConnectedAccount.fetchOne(db, key: email)
                ?? ConnectedAccount(email: email, displayName: nil, colorHex: color,
                                    addedAt: Date(), needsReauth: false, lastSyncAt: nil, lastSyncError: nil)
            account.needsReauth = false
            try account.save(db)

            for entry in calendars {
                let isPrimary = entry.primary == true
                var source = try CalendarSource.fetchOne(db, key: ["accountEmail": email, "calendarId": entry.id])
                    ?? CalendarSource(accountEmail: email, calendarId: entry.id,
                                      summary: entry.summaryOverride ?? entry.summary ?? entry.id,
                                      colorHex: entry.backgroundColor, isPrimary: isPrimary,
                                      accessRole: entry.accessRole ?? "reader",
                                      isSelected: isPrimary) // default: primary selected, others off
                source.summary = entry.summaryOverride ?? entry.summary ?? entry.id
                source.colorHex = entry.backgroundColor
                source.isPrimary = isPrimary
                source.accessRole = entry.accessRole ?? "reader"
                try source.save(db)
            }
        }
    }
}
