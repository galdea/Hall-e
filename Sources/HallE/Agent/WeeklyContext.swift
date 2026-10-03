import Foundation
import GRDB

/// Connector-neutral handoff. Import is explicit; this contract grants no connector access.
struct WeeklyContextEnvelope: Codable, Equatable {
    static let schema = "halle.weekly-context.v1"
    var schemaVersion: String
    var sources: [WeeklyContextSource]
}

struct WeeklyContextSource: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case email, calendar, repositories, tasks, teaching, life }
    var id: String
    var kind: Kind
    var label: String
    var scope: String
    var authorized: Bool
    var authorizationReference: String?
    var collectedAt: Date
    var coveredFrom: Date
    var coveredTo: Date
    var completeScope: Bool
    var items: [WeeklyContextItem]
    var error: String?

    enum Coverage: String { case current, partial, stale, unauthorized, unavailable }
    func coverage(for interval: DateInterval, now: Date) -> Coverage {
        guard authorized, authorizationReference?.isEmpty == false else { return .unauthorized }
        guard error == nil else { return .unavailable }
        guard collectedAt <= now.addingTimeInterval(60), now.timeIntervalSince(collectedAt) <= 24 * 3600 else { return .stale }
        return completeScope && coveredFrom <= interval.start && coveredTo >= interval.end ? .current : .partial
    }
}

struct WeeklyContextItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var occurredAt: Date?
    var citation: String
}

struct CalendarSyncReceipt: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "calendar_sync_receipt"
    var id: String
    var accountEmail: String
    var calendarID: String
    var coveredFrom: Date
    var coveredTo: Date
    var fetchedAt: Date
}

enum WeeklyContextContract {
    static func decode(_ data: Data) throws -> WeeklyContextEnvelope {
        guard data.count <= 5_000_000 else { throw CalendarCreationError.validation("The weekly context packet exceeds 5 MB.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(WeeklyContextEnvelope.self, from: data)
        guard envelope.schemaVersion == WeeklyContextEnvelope.schema,
              Set(envelope.sources.map(\.id)).count == envelope.sources.count else {
            throw CalendarCreationError.validation("Unsupported weekly context schema or duplicate source identity.")
        }
        for source in envelope.sources {
            guard !source.id.isEmpty, !source.label.isEmpty, !source.scope.isEmpty,
                  source.coveredTo > source.coveredFrom, source.items.count <= 5000,
                  Set(source.items.map(\.id)).count == source.items.count,
                  source.items.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty && !$0.citation.isEmpty }) else {
                throw CalendarCreationError.validation("Each source needs an explicit scope, coverage window and cited items.")
            }
        }
        return envelope
    }
    static func markdown(sources: [WeeklyContextSource], interval: DateInterval, now: Date) -> String {
        var lines = ["# On-demand weekly review", "", "Window: \(interval.start.formatted(date: .abbreviated, time: .omitted)) – \(interval.end.formatted(date: .abbreviated, time: .omitted)) (end exclusive)",
                     "Only the listed authorized scopes are assessed. Missing sources and partial coverage remain explicit.", ""]
        for kind in WeeklyContextSource.Kind.allCases {
            lines += ["## \(kind.rawValue.capitalized)"]
            let matching = sources.filter { $0.kind == kind }
            if matching.isEmpty { lines += ["Not connected or imported.", ""]; continue }
            for source in matching {
                let coverage = source.coverage(for: interval, now: now)
                lines += ["### \(source.label)", "Scope: \(source.scope)", "Coverage: \(coverage.rawValue) · collected \(source.collectedAt.formatted())"]
                guard coverage != .unauthorized && coverage != .unavailable else { lines += [source.error ?? "This source is excluded.", ""]; continue }
                for item in source.items.filter({ $0.occurredAt.map { interval.contains($0) && $0 < interval.end } ?? true }) {
                    lines += ["- \(item.title)", "  \(item.detail)", "  Source: \(item.citation)"]
                }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }
}
