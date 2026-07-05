import os

/// Central os.Logger categories. Never log secrets, tokens, or transcript text.
enum Log {
    private static let subsystem = "cl.gabriel.hall-e"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let db = Logger(subsystem: subsystem, category: "db")
    static let oauth = Logger(subsystem: subsystem, category: "oauth")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let notify = Logger(subsystem: subsystem, category: "notify")
    static let obsidian = Logger(subsystem: subsystem, category: "obsidian")
    static let intel = Logger(subsystem: subsystem, category: "intelligence")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let rec = Logger(subsystem: subsystem, category: "recording")
}
