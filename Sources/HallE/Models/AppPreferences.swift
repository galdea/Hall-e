import Foundation

/// Non-secret user preferences, stored in UserDefaults (domain cl.gabriel.hall-e).
/// Secrets never live here — those go to Keychain.
struct AppPreferences {
    private static let d = UserDefaults.standard

    private enum Key {
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let notificationLeadMinutes = "notificationLeadMinutes"
        static let windowPastDays = "windowPastDays"
        static let windowFutureDays = "windowFutureDays"
        static let showDeclinedEvents = "showDeclinedEvents"
        static let primaryAccountEmail = "primaryAccountEmail"
        static let obsidianVaultConfig = "obsidianVaultConfig"
        static let llmProviderConfig = "llmProviderConfig"
    }

    static var refreshIntervalMinutes: Int {
        get { d.object(forKey: Key.refreshIntervalMinutes) as? Int ?? 5 }
        set { d.set(newValue, forKey: Key.refreshIntervalMinutes) }
    }

    static var notificationLeadMinutes: Int {
        get { d.object(forKey: Key.notificationLeadMinutes) as? Int ?? 15 }
        set { d.set(newValue, forKey: Key.notificationLeadMinutes) }
    }

    static var windowPastDays: Int {
        get { d.object(forKey: Key.windowPastDays) as? Int ?? 1 }
        set { d.set(newValue, forKey: Key.windowPastDays) }
    }

    static var windowFutureDays: Int {
        get { d.object(forKey: Key.windowFutureDays) as? Int ?? 7 }
        set { d.set(newValue, forKey: Key.windowFutureDays) }
    }

    static var showDeclinedEvents: Bool {
        get { d.bool(forKey: Key.showDeclinedEvents) }
        set { d.set(newValue, forKey: Key.showDeclinedEvents) }
    }

    static var primaryAccountEmail: String? {
        get { d.string(forKey: Key.primaryAccountEmail) }
        set { d.set(newValue, forKey: Key.primaryAccountEmail) }
    }

    // Codable blobs stored as JSON data.

    static func codable<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func setCodable<T: Codable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            d.set(data, forKey: key)
        } else {
            d.removeObject(forKey: key)
        }
    }

    static var obsidianVaultConfigKey: String { Key.obsidianVaultConfig }
    static var llmProviderConfigKey: String { Key.llmProviderConfig }
}
