import Foundation

/// Pulls a JSON object out of an LLM reply that may wrap it in prose or code
/// fences, then applies light repairs. Lenient by design — models are sloppy.
enum JSONExtractor {
    /// Extract the first balanced top-level `{…}` object as `Data`, or nil.
    static func extractObject(_ raw: String) -> Data? {
        let stripped = stripFences(raw)
        guard let slice = firstBalancedObject(stripped) else { return nil }
        let repaired = repair(slice)
        return repaired.data(using: .utf8)
    }

    /// Decode a Codable type from an LLM reply, with repair + validation.
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        guard let data = extractObject(raw) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Steps

    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // Drop the opening fence line (``` or ```json) and the closing fence.
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if let closing = t.range(of: "```", options: .backwards) {
                t = String(t[..<closing.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scan for the first `{` … matching `}`, respecting strings and escapes.
    static func firstBalancedObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(s[start...i]) }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Light repairs: trailing commas, smart quotes.
    static func repair(_ s: String) -> String {
        var t = s
            .replacingOccurrences(of: "\u{201C}", with: "\"")  // “
            .replacingOccurrences(of: "\u{201D}", with: "\"")  // ”
            .replacingOccurrences(of: "\u{2018}", with: "'")   // ‘
            .replacingOccurrences(of: "\u{2019}", with: "'")   // ’
        // Remove trailing commas before } or ]
        t = t.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        return t
    }
}
