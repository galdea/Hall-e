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
        static let autoPromptWhatsAppCalls = "autoPromptWhatsAppCalls"
        static let autoRecordCalendarMeetings = "autoRecordCalendarMeetings"
        static let stopRecordingAtScheduledEnd = "stopRecordingAtScheduledEnd"
        static let transcriptionRecoveryMigration = "transcriptionRecoveryMigration"
        static let recordingLayoutMigration = "recordingLayoutMigration"
        static let enabledCallSources = "enabledCallSources"
        static let customCallDomains = "customCallDomains"
        static let chromeExtensionID = "chromeExtensionID"
        static let primaryAccountEmail = "primaryAccountEmail"
        static let obsidianVaultConfig = "obsidianVaultConfig"
        static let llmProviderConfig = "llmProviderConfig"
        static let appLanguage = "appLanguage"
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingStep = "onboardingStep"
        static let notificationsEnabled = "notificationsEnabled"
        static let quietHoursStart = "quietHoursStart"
        static let quietHoursEnd = "quietHoursEnd"
        static let transcriptionEngine = "transcriptionEngine"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let cloudAudioConsent = "cloudAudioConsent"
        static let cloudTranscriptConsent = "cloudTranscriptConsent"
        static let deepgramMonthlyLimitUSD = "deepgramMonthlyLimitUSD"
    }

    static var refreshIntervalMinutes: Int {
        get { d.object(forKey: Key.refreshIntervalMinutes) as? Int ?? 5 }
        set { d.set(newValue, forKey: Key.refreshIntervalMinutes) }
    }

    static var notificationLeadMinutes: Int {
        get { d.object(forKey: Key.notificationLeadMinutes) as? Int ?? 5 }
        set { d.set(newValue, forKey: Key.notificationLeadMinutes) }
    }

    static var windowPastDays: Int {
        get { d.object(forKey: Key.windowPastDays) as? Int ?? 1 }
        set { d.set(newValue, forKey: Key.windowPastDays) }
    }

    static var windowFutureDays: Int {
        get { d.object(forKey: Key.windowFutureDays) as? Int ?? 21 }
        set { d.set(newValue, forKey: Key.windowFutureDays) }
    }

    static var showDeclinedEvents: Bool {
        get { d.bool(forKey: Key.showDeclinedEvents) }
        set { d.set(newValue, forKey: Key.showDeclinedEvents) }
    }

    static var autoPromptWhatsAppCalls: Bool {
        get { d.object(forKey: Key.autoPromptWhatsAppCalls) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autoPromptWhatsAppCalls) }
    }

    static var autoRecordCalendarMeetings: Bool {
        get { d.object(forKey: Key.autoRecordCalendarMeetings) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.autoRecordCalendarMeetings) }
    }

    static var stopRecordingAtScheduledEnd: Bool {
        get { d.object(forKey: Key.stopRecordingAtScheduledEnd) as? Bool ?? false }
        set { d.set(newValue, forKey: Key.stopRecordingAtScheduledEnd) }
    }

    /// Bumps when the durable transcription job schema changes. The migration is
    /// intentionally one-shot so an old failed recording is retried once, not on
    /// every app launch forever.
    static var transcriptionRecoveryMigration: Int {
        get { d.object(forKey: Key.transcriptionRecoveryMigration) as? Int ?? 0 }
        set { d.set(newValue, forKey: Key.transcriptionRecoveryMigration) }
    }

    /// Bumps when the on-disk recordings layout changes. One-shot: the flat
    /// `Recordings/<slug>` folders are filed under their project exactly once.
    static var recordingLayoutMigration: Int {
        get { d.object(forKey: Key.recordingLayoutMigration) as? Int ?? 0 }
        set { d.set(newValue, forKey: Key.recordingLayoutMigration) }
    }

    static var enabledCallSources: Set<String> {
        get {
            guard let values = d.array(forKey: Key.enabledCallSources) as? [String] else {
                return ["chrome", "zoom", "whatsapp"]
            }
            return Set(values)
        }
        set { d.set(Array(newValue).sorted(), forKey: Key.enabledCallSources) }
    }

    static var customCallDomains: [String] {
        get { d.stringArray(forKey: Key.customCallDomains) ?? [] }
        set { d.set(newValue, forKey: Key.customCallDomains) }
    }

    static var chromeExtensionID: String? {
        get { d.string(forKey: Key.chromeExtensionID) }
        set { d.set(newValue, forKey: Key.chromeExtensionID) }
    }

    static var primaryAccountEmail: String? {
        get { d.string(forKey: Key.primaryAccountEmail) }
        set { d.set(newValue, forKey: Key.primaryAccountEmail) }
    }

    static var appLanguage: String {
        get { d.string(forKey: Key.appLanguage) ?? "system" }
        set { d.set(newValue, forKey: Key.appLanguage) }
    }

    static var onboardingCompleted: Bool {
        get { d.bool(forKey: Key.onboardingCompleted) }
        set { d.set(newValue, forKey: Key.onboardingCompleted) }
    }

    static var onboardingStep: Int {
        get { d.object(forKey: Key.onboardingStep) as? Int ?? 0 }
        set { d.set(newValue, forKey: Key.onboardingStep) }
    }

    static var notificationsEnabled: Bool {
        get { d.object(forKey: Key.notificationsEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.notificationsEnabled) }
    }

    static var quietHoursStart: Int {
        get { d.object(forKey: Key.quietHoursStart) as? Int ?? 22 }
        set { d.set(newValue, forKey: Key.quietHoursStart) }
    }

    static var quietHoursEnd: Int {
        get { d.object(forKey: Key.quietHoursEnd) as? Int ?? 8 }
        set { d.set(newValue, forKey: Key.quietHoursEnd) }
    }

    static func isQuietHour(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date), start = quietHoursStart, end = quietHoursEnd
        return start <= end ? (start..<end).contains(hour) : hour >= start || hour < end
    }

    static var transcriptionEngine: TranscriptionEnginePreference {
        get { TranscriptionEnginePreference(rawValue: d.string(forKey: Key.transcriptionEngine) ?? "auto") ?? .auto }
        set { d.set(newValue.rawValue, forKey: Key.transcriptionEngine) }
    }

    static var transcriptionLanguage: TranscriptionLanguagePreference {
        get { TranscriptionLanguagePreference(rawValue: d.string(forKey: Key.transcriptionLanguage) ?? "auto") ?? .auto }
        set { d.set(newValue.rawValue, forKey: Key.transcriptionLanguage) }
    }

    static var cloudAudioConsent: CloudProcessingConsent? {
        get { codable(CloudProcessingConsent.self, forKey: Key.cloudAudioConsent) }
        set { setCodable(newValue, forKey: Key.cloudAudioConsent) }
    }

    static var cloudTranscriptConsent: CloudProcessingConsent? {
        get { codable(CloudProcessingConsent.self, forKey: Key.cloudTranscriptConsent) }
        set { setCodable(newValue, forKey: Key.cloudTranscriptConsent) }
    }

    static var allowCloudAudioTranscription: Bool { cloudAudioConsent?.isActive == true }
    static var allowCloudTranscriptReports: Bool { cloudTranscriptConsent?.isActive == true }

    static var deepgramMonthlyLimitUSD: Double {
        get {
            let value = d.double(forKey: Key.deepgramMonthlyLimitUSD)
            return value > 0 ? value : 25
        }
        set { d.set(max(1, newValue), forKey: Key.deepgramMonthlyLimitUSD) }
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
