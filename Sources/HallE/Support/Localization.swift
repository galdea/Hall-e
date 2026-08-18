import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", spanish = "es"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: L10n.text("language.system")
        case .english: "English"
        case .spanish: "Español"
        }
    }
}

@MainActor
@Observable
final class AppLanguageStore {
    static let shared = AppLanguageStore()
    var language: AppLanguage {
        didSet { AppPreferences.appLanguage = language.rawValue }
    }

    private init() {
        language = AppLanguage(rawValue: AppPreferences.appLanguage) ?? .system
    }

    var locale: Locale {
        switch language {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .spanish: Locale(identifier: "es")
        }
    }
}

enum L10n {
    static func text(_ key: String) -> String {
        let language = AppPreferences.appLanguage
        let bundle: Bundle
        if language != "system",
           let path = Bundle.module.path(forResource: language, ofType: "lproj"),
           let localized = Bundle(path: path) {
            bundle = localized
        } else {
            bundle = .module
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let code = AppPreferences.appLanguage
        let locale = code == "system" ? Locale.autoupdatingCurrent : Locale(identifier: code)
        return String(format: text(key), locale: locale, arguments: arguments)
    }
}
