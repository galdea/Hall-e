import Foundation

/// Well-known on-disk locations for Hall-e, all under Application Support.
enum AppPaths {
    static let bundleID = "cl.gabriel.hall-e"

    /// ~/Library/Application Support/Hall-e
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Hall-e", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        return dir
    }
}
