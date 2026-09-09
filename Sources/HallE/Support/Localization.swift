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
           let path = AppResources.bundle.path(forResource: language, ofType: "lproj"),
           let localized = Bundle(path: path) {
            bundle = localized
        } else {
            bundle = AppResources.bundle
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let code = AppPreferences.appLanguage
        let locale = code == "system" ? Locale.autoupdatingCurrent : Locale(identifier: code)
        return String(format: text(key), locale: locale, arguments: arguments)
    }
}

/// Signed app bundles keep resources under Contents/Resources. SwiftPM's
/// generated accessor otherwise falls back to an absolute build-cache path.
enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("HallE_HallE.bundle"),
           let bundled = Bundle(url: url) {
            return bundled
        }
        return Bundle.module
    }()
}
