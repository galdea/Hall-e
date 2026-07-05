import Foundation

/// Thread-safe date formatting helpers. `DateFormatter` instances are not
/// thread-safe, and Hall-e formats dates from multiple actors/tasks
/// concurrently, so we allocate a fresh formatter per call (cheap at our volume)
/// with a fixed POSIX locale and the current time zone.
enum HalleDate {
    static func day(_ date: Date) -> String { format("yyyy-MM-dd", date) }
    static func time(_ date: Date) -> String { format("HH:mm", date) }
    static func yearMonth(_ date: Date) -> String { format("yyyy-MM", date) }
    static func year(_ date: Date) -> String { format("yyyy", date) }

    private static func format(_ pattern: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
