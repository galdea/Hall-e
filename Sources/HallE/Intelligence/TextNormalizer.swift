import Foundation

/// Normalizes text for keyword matching: diacritic- and case-folded, so
/// "Viña Cousiño" matches "vina cousino" and "Matríztica" matches "matriztica".
enum TextNormalizer {
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "es"))
    }

    /// Whole-word (token-boundary) containment: does `haystack` contain `needle`
    /// as a run of whole words? Both are folded first.
    static func containsPhrase(_ haystack: String, _ needle: String) -> Bool {
        let h = fold(haystack)
        let n = fold(needle).trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return false }
        let hTokens = tokenize(h)
        let nTokens = tokenize(n)
        guard !nTokens.isEmpty, nTokens.count <= hTokens.count else { return false }
        for start in 0...(hTokens.count - nTokens.count) {
            if Array(hTokens[start..<start + nTokens.count]) == nTokens { return true }
        }
        return false
    }

    /// Split on non-alphanumeric boundaries (keeps accented letters after folding
    /// removed them → plain latin + digits).
    static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func domain(ofEmail email: String) -> String? {
        guard let at = email.firstIndex(of: "@") else { return nil }
        return String(email[email.index(after: at)...]).lowercased()
    }
}
