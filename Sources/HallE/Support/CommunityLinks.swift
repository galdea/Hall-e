import Foundation

enum CommunityLinks {
    static let github = URL(string: "https://github.com/galdea/Hall-e")!
    // Replace only when the maintainer supplies a donation destination.
    static let support = URL(string: "https://github.com/galdea/Hall-e#support")!
}

/// Inline bilingual copy while shared localization catalogs are being edited separately.
enum PublicUICopy {
    static func text(_ english: String, _ spanish: String) -> String {
        let code = AppPreferences.appLanguage
        let isSpanish = code == "es" || (code == "system" && Locale.autoupdatingCurrent.language.languageCode?.identifier == "es")
        return isSpanish ? spanish : english
    }
}
