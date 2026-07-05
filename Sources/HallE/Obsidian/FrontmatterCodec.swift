import Foundation

/// Minimal YAML-frontmatter reader/updater for the scalar keys Hall-e owns
/// (e.g. hall_e_event_id, transcript_status, recording_path, project). It does
/// not reformat the body or list-valued keys — it only reads/patches top-level
/// `key: value` lines inside the leading `---` block, leaving everything else
/// untouched.
enum FrontmatterCodec {
    /// Returns the frontmatter line range (indices into components(separatedBy:"\n"))
    /// as (openIndex, closeIndex) if a leading `---` … `---` block exists.
    private static func frontmatterRange(_ lines: [String]) -> (Int, Int)? {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return (0, i)
        }
        return nil
    }

    static func readValue(_ content: String, key: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard let (open, close) = frontmatterRange(lines) else { return nil }
        for i in (open + 1)..<close {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            if k == key {
                var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                v = stripQuotes(v)
                return v
            }
        }
        return nil
    }

    /// Update `key` to `value` inside the frontmatter, or insert it if absent.
    /// If the note has no frontmatter block, one is created.
    static func updateValue(_ content: String, key: String, value: String, quoted: Bool = true) -> String {
        var lines = content.components(separatedBy: "\n")
        let rendered = "\(key): \(quoted ? "\"\(escape(value))\"" : value)"

        guard let (open, close) = frontmatterRange(lines) else {
            // No frontmatter — prepend one.
            return (["---", rendered, "---", ""] + lines).joined(separator: "\n")
        }
        for i in (open + 1)..<close {
            if let colon = lines[i].firstIndex(of: ":") {
                let k = lines[i][..<colon].trimmingCharacters(in: .whitespaces)
                if k == key { lines[i] = rendered; return lines.joined(separator: "\n") }
            }
        }
        lines.insert(rendered, at: close) // insert just before the closing ---
        return lines.joined(separator: "\n")
    }

    private static func stripQuotes(_ s: String) -> String {
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
