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
    /// If the first balanced `{…}` doesn't decode (e.g. a stray `{}` in the
    /// model's prose before the real payload), later objects are tried.
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let decoder = JSONDecoder()
        var remaining = Substring(stripFences(raw))
        while let start = remaining.firstIndex(of: "{") {
            if let object = firstBalancedObject(String(remaining[start...])),
               let data = repair(object).data(using: .utf8),
               let value = try? decoder.decode(T.self, from: data) {
                return value
            }
            remaining = remaining[remaining.index(after: start)...]
        }
        return nil
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

    /// Light repairs: smart quotes used as delimiters, trailing commas.
    /// String-aware: characters inside proper `"…"` literals are left alone so
    /// a summary containing “quotes” or a literal `,]` isn't corrupted.
    static func repair(_ s: String) -> String {
        // Pass 1: normalize smart quotes acting as string delimiters.
        var normalized = ""
        normalized.reserveCapacity(s.count)
        var inString = false
        var smartOpened = false
        var escaped = false
        for c in s {
            if inString {
                if escaped { escaped = false; normalized.append(c); continue }
                if c == "\\" { escaped = true; normalized.append(c); continue }
                if c == "\"" || (smartOpened && c == "\u{201D}") {
                    inString = false; smartOpened = false
                    normalized.append("\"")
                    continue
                }
                normalized.append(c)
            } else {
                switch c {
                case "\"": inString = true; smartOpened = false; normalized.append("\"")
                case "\u{201C}", "\u{201D}": inString = true; smartOpened = true; normalized.append("\"")
                case "\u{2018}", "\u{2019}": normalized.append("'")
                default: normalized.append(c)
                }
            }
        }
        // Pass 2: drop trailing commas before } or ], outside strings only.
        var out = ""
        out.reserveCapacity(normalized.count)
        inString = false
        escaped = false
        var i = normalized.startIndex
        while i < normalized.endIndex {
            let c = normalized[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                out.append(c)
            } else if c == "\"" {
                inString = true
                out.append(c)
            } else if c == "," {
                var j = normalized.index(after: i)
                while j < normalized.endIndex, normalized[j].isWhitespace { j = normalized.index(after: j) }
                if !(j < normalized.endIndex && (normalized[j] == "}" || normalized[j] == "]")) {
                    out.append(c)
                }
            } else {
                out.append(c)
            }
            i = normalized.index(after: i)
        }
        return out
    }
}
