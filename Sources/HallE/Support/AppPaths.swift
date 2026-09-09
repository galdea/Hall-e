import Foundation

/// Well-known on-disk locations for Hall-e, all under Application Support.
enum AppPaths {
    static let bundleID = "cl.gabriel.hall-e"

    /// ~/Library/Application Support/Hall-e
    static var appSupport: URL {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HALLE_DEBUG_FIXTURES"] == "1" {
            let root = ProcessInfo.processInfo.environment["HALLE_DEBUG_DATA_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("Hall-e-Preview-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Hall-e", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// SQLite database file (WAL mode).
    static var databaseFile: URL {
        appSupport.appendingPathComponent("halle.sqlite")
    }

    /// Imported Google Desktop OAuth client (installed.*), 0600.
    static var googleClientFile: URL {
        appSupport.appendingPathComponent("google-client.json")
    }

    /// Editable project aliases / rules.
    static var aliasesFile: URL {
        appSupport.appendingPathComponent("aliases.json")
    }

    /// People directory (name → projects, emails, phones).
    static var peopleFile: URL {
        appSupport.appendingPathComponent("people.json")
    }

    /// User classification pins (event-id / recurring-series → project).
    static var userRulesFile: URL {
        appSupport.appendingPathComponent("user-rules.json")
    }

    /// Raw recordings live outside the Obsidian vault by default.
    static var recordingsDir: URL {
        let dir = appSupport.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    static var vaultIndexFile: URL {
        appSupport.appendingPathComponent("vault-index.json")
    }

    /// Kept at the original filename so existing spend reservations remain in
    /// force after the ledger becomes provider-labelled.
    static var cloudTranscriptionSpendLedgerFile: URL {
        appSupport.appendingPathComponent("deepgram-spend-ledger.json")
    }

    /// Successful Deepgram responses, keyed by audio digest + request options.
    /// ADR 0001 requires raw responses to be reusable so normalization can be
    /// repeated without paying for a second transcription. The A/B gate and the
    /// full backfill therefore transcribe the same audio only once.
    static var deepgramResponseCacheDir: URL {
        let dir = backfillDirectory.appendingPathComponent("RawResponses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    static var speechmaticsResponseCacheDir: URL {
        let dir = backfillDirectory.appendingPathComponent("SpeechmaticsRawResponses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// Non-promoting A/B sample output. Nothing here is an active artifact.
    static var deepgramSampleDirectory: URL {
        let dir = backfillDirectory.appendingPathComponent("Samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    static var backfillDirectory: URL {
        let dir = appSupport.appendingPathComponent("Backfill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// One JSON file per native-message payload. Per-message files avoid a
    /// shared append race between Chrome's short-lived native hosts.
    static var callMessageQueueDirectory: URL {
        let dir = appSupport.appendingPathComponent("CallCapture/Incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// A stable, user-loadable copy of the bundled Chrome extension. Keeping it
    /// in Application Support avoids Chrome losing the extension whenever a
    /// signed Hall-e app bundle is replaced during an upgrade.
    static var browserExtensionDirectory: URL {
        let dir = appSupport.appendingPathComponent("BrowserExtension", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
}
