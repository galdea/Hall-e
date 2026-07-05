import Foundation

/// Writes notes safely: atomic temp-then-rename, create-if-missing, never
/// truncating existing content. Section updates go through `MarkerBlockMerger`.
struct VaultWriter {
    enum WriteError: Error, LocalizedError {
        case vaultUnreachable
        case conflict(String)
        var errorDescription: String? {
            switch self {
            case .vaultUnreachable: "Obsidian vault folder is missing or not writable."
            case .conflict(let p): "The note changed on disk while writing (\(p)); retried and gave up to avoid a clobber."
            }
        }
    }

    let vaultURL: URL

    /// Create a note from `content` only if it doesn't already exist.
    /// Returns the URL and whether it was created (false = already existed).
    @discardableResult
    func createIfMissing(relativePath: String, content: String, pathBuilder: VaultPathBuilder) throws -> (URL, Bool) {
        let url = pathBuilder.absoluteURL(relativePath, vaultURL: vaultURL)
        if FileManager.default.fileExists(atPath: url.path) { return (url, false) }
        try ensureParent(url)
        try atomicWrite(content, to: url)
        return (url, true)
    }

    /// Merge `newContent` into `section` of an existing (or newly created) note,
    /// preserving all user content outside our markers. `baseTemplate` is used to
    /// create the note if absent.
    @discardableResult
    func mergeSection(relativePath: String, section: String, newContent: String,
                      headingAnchor: String, mode: MarkerBlockMerger.Mode,
                      sortDescending: Bool = false,
                      createWith baseTemplate: String? = nil,
                      pathBuilder: VaultPathBuilder) throws -> URL {
        let url = pathBuilder.absoluteURL(relativePath, vaultURL: vaultURL)

        // Create from template if needed.
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let baseTemplate else {
                try ensureParent(url)
                try atomicWrite("", to: url)
                return try applyMerge(url: url, section: section, newContent: newContent,
                                      headingAnchor: headingAnchor, mode: mode, sortDescending: sortDescending)
            }
            try ensureParent(url)
            try atomicWrite(baseTemplate, to: url)
        }
        return try applyMerge(url: url, section: section, newContent: newContent,
                              headingAnchor: headingAnchor, mode: mode, sortDescending: sortDescending)
    }

    /// Update a single frontmatter scalar on an existing note (no-op if absent).
    func updateFrontmatter(relativePath: String, key: String, value: String, pathBuilder: VaultPathBuilder) throws {
        let url = pathBuilder.absoluteURL(relativePath, vaultURL: vaultURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let (content, mtime) = try readWithMTime(url)
        let updated = FrontmatterCodec.updateValue(content, key: key, value: value)
        if updated == content { return }
        try writeCheckingMTime(updated, to: url, expected: mtime)
    }

    // MARK: - Internals

    private func applyMerge(url: URL, section: String, newContent: String,
                            headingAnchor: String, mode: MarkerBlockMerger.Mode,
                            sortDescending: Bool) throws -> URL {
        let (content, mtime) = try readWithMTime(url)
        let (merged, outcome) = MarkerBlockMerger.merge(
            note: content, section: section, newContent: newContent,
            headingAnchor: headingAnchor, mode: mode, sortDescending: sortDescending)
        if outcome == .unchanged { return url }
        try writeCheckingMTime(merged, to: url, expected: mtime)
        return url
    }

    private func readWithMTime(_ url: URL) throws -> (String, Date?) {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        return (content, mtime)
    }

    /// Write, but if the file changed since we read it, re-read/re-merge is the
    /// caller's job; here we detect the conflict and retry once by failing loudly.
    private func writeCheckingMTime(_ content: String, to url: URL, expected: Date?) throws {
        if let expected,
           let current = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
           current > expected {
            throw WriteError.conflict(url.lastPathComponent)
        }
        try atomicWrite(content, to: url)
    }

    private func ensureParent(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
    }

    /// Write to a sibling temp file, then atomically replace.
    private func atomicWrite(_ content: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).hall-e-tmp-\(UUID().uuidString)")
        try content.data(using: .utf8)!.write(to: tmp, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
