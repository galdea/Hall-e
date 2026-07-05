import Foundation

/// Non-destructive section merge for Markdown notes. Hall-e only ever changes
/// content *between its own HTML-comment markers*; everything the user wrote
/// outside those markers is preserved byte-for-byte.
///
/// Strategy, in order:
///   1. If our marker block exists → replace / append inside it.
///   2. Else if a matching heading exists → insert a fresh marker block at the
///      END of that heading's section (user's prose above is untouched).
///   3. Else → append a new "## heading" + marker block at end of file.
///
/// Invariants (unit-tested): no line outside a marker interior is modified;
/// merging the same content twice is a no-op; corrupted/half-deleted markers are
/// never "guessed" — we fall through and append rather than delete user text.
enum MarkerBlockMerger {
    enum Mode {
        case replace       // block interior becomes exactly newContent
        case appendLines   // union new lines into the block (for indexes/daily notes)
    }

    enum Outcome: Equatable {
        case unchanged, mergedViaMarkers, mergedViaHeading, appendedAtEnd
    }

    static func startMarker(_ section: String) -> String { "<!-- hall-e:\(section):start -->" }
    static func endMarker(_ section: String) -> String { "<!-- hall-e:\(section):end -->" }

    static func merge(note: String, section: String, newContent: String,
                      headingAnchor: String, mode: Mode,
                      sortDescending: Bool = false) -> (text: String, outcome: Outcome) {
        let start = startMarker(section)
        let end = endMarker(section)
        var lines = note.components(separatedBy: "\n")
        let newLines = newContent.isEmpty ? [] : newContent.components(separatedBy: "\n")

        // Strategy 1: existing markers.
        if let si = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == start }),
           let ei = lines[(si + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end }) {
            let interior = Array(lines[(si + 1)..<ei])
            let merged: [String]
            switch mode {
            case .replace:
                merged = newLines
            case .appendLines:
                let existing = Set(interior.map { $0.trimmingCharacters(in: .whitespaces) })
                let additions = newLines.filter { !existing.contains($0.trimmingCharacters(in: .whitespaces)) }
                merged = sortLines(interior + additions, descending: sortDescending)
            }
            if merged == interior { return (note, .unchanged) }
            lines.replaceSubrange((si + 1)..<ei, with: merged)
            return (lines.joined(separator: "\n"), .mergedViaMarkers)
        }

        // Strategy 2: heading anchor (user removed our markers but kept the section).
        let foldedAnchor = fold(headingAnchor)
        if let hi = lines.firstIndex(where: { isHeading($0, matching: foldedAnchor) }) {
            let level = headingLevel(lines[hi])
            // Section ends at the next heading of same-or-higher level, else EOF.
            var sectionEnd = lines.count
            for j in (hi + 1)..<lines.count {
                let l = headingLevel(lines[j])
                if l > 0 && l <= level { sectionEnd = j; break }
            }
            var insert = [""] + [start] + newLines + [end]
            // Trim a leading blank if the preceding line is already blank.
            if sectionEnd > 0, lines[sectionEnd - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insert.removeFirst()
            }
            lines.insert(contentsOf: insert, at: sectionEnd)
            return (lines.joined(separator: "\n"), .mergedViaHeading)
        }

        // Strategy 3: append at EOF with a fresh heading + block.
        var suffix: [String] = []
        if !(lines.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) { suffix.append("") }
        suffix += ["## \(headingAnchor)", start] + newLines + [end]
        lines.append(contentsOf: suffix)
        return (lines.joined(separator: "\n"), .appendedAtEnd)
    }

    // MARK: - Helpers

    private static func sortLines(_ lines: [String], descending: Bool) -> [String] {
        guard descending else { return lines }
        return lines.sorted(by: >)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func headingLevel(_ line: String) -> Int {
        let t = line.drop(while: { $0 == " " })
        var n = 0
        for ch in t { if ch == "#" { n += 1 } else { break } }
        // Must be "#…# " followed by text to count as a heading.
        if n > 0, t.dropFirst(n).first == " " { return n }
        return 0
    }

    private static func isHeading(_ line: String, matching foldedAnchor: String) -> Bool {
        let level = headingLevel(line)
        guard level > 0 else { return false }
        let title = line.drop(while: { $0 == " " }).dropFirst(level)
            .trimmingCharacters(in: .whitespaces)
        return fold(title) == foldedAnchor
    }
}
