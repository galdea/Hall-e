import Foundation

/// Makes safe, stable filenames for notes. Removes path-hostile and
/// filesystem-illegal characters, collapses whitespace, and bounds length by
/// UTF-8 byte count (APFS limit is 255 bytes).
enum FilenameSanitizer {
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")

    static func sanitize(_ raw: String, maxBytes: Int = 180) -> String {
        // Normalize (NFC) so accented chars are single code points.
        var s = raw.precomposedStringWithCanonicalMapping

        // Replace illegal + control chars with a space.
        s = String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            if illegal.contains(scalar) || scalar.properties.generalCategory == .control {
                return " "
            }
            return scalar
        }))

        // Collapse whitespace runs, trim.
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
             .joined(separator: " ")
             .trimmingCharacters(in: .whitespaces)

        // Leading dots make hidden files; strip them.
        while s.hasPrefix(".") { s.removeFirst() }

        if s.isEmpty { s = "Untitled" }

        // Bound by UTF-8 bytes without splitting a character.
        if s.utf8.count > maxBytes {
            var truncated = ""
            var count = 0
            for ch in s {
                let n = String(ch).utf8.count
                if count + n > maxBytes { break }
                truncated.append(ch); count += n
            }
            s = truncated.trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
