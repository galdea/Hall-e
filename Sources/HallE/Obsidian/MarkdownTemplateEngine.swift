import Foundation

/// Trivial `{{placeholder}}` substitution over code-constant templates. Missing
/// keys render as empty strings. Kept separate so templates can move to files later.
enum MarkdownTemplateEngine {
    static func render(_ template: String, _ values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        // Blank any leftover placeholders.
        while let range = result.range(of: "\\{\\{[a-zA-Z0-9_]+\\}\\}", options: .regularExpression) {
            result.replaceSubrange(range, with: "")
        }
        return result
    }
}
