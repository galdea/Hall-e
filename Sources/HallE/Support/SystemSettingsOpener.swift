import AppKit

/// Deep links into System Settings for permissions the app can no longer
/// prompt for (macOS only shows the TCC dialog once; after a denial the user
/// must flip the switch themselves).
enum SystemSettingsOpener {
    static func openInternetAccounts() {
        if !open("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            _ = open("x-apple.systempreferences:com.apple.preferences.internetaccounts")
        }
    }

    static func openCalendarPrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    static func openMicrophonePrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openSpeechPrivacy() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    static func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? AppPaths.bundleID
        let appSettings = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?bundleId=\(bundleID)"
        if !open(appSettings) {
            _ = open("x-apple.systempreferences:com.apple.preference.notifications")
        }
    }

    @discardableResult
    private static func open(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
