import Foundation
import GRDB

enum CallProvider: String, Codable, CaseIterable, Hashable {
    case googleMeet = "google-meet"
    case zoom
    case teams
    case whatsApp = "whatsapp"
    case jitsi
    case whereby
    case custom
    case zoomDesktop = "zoom-desktop"

    var displayName: String {
        switch self {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .whatsApp: "WhatsApp"
        case .jitsi: "Jitsi"
        case .whereby: "Whereby"
        case .custom: "Browser call"
        case .zoomDesktop: "Zoom"
        }
    }

    var recordingSource: RecordingSourceKind {
        switch self {
        case .whatsApp: .whatsAppCall
        case .zoom, .zoomDesktop: .zoomCall
        default: .chromeCall
        }
    }
}

/// A stable, privacy-minimal identity for an approved call URL. It intentionally
/// excludes page title, query tracking, and unrelated browsing state.
struct CallIdentity: Codable, Hashable, Identifiable {
    var provider: CallProvider
    var normalizedURL: String

    var id: String { key }
    var key: String { "\(provider.rawValue):\(normalizedURL)" }

    static func make(url: URL, customDomains: [String] = AppPreferences.customCallDomains) -> CallIdentity? {
        guard let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return nil }
        let path = normalizedPath(url.path)
        let provider: CallProvider
        let canonicalPath: String

        if host == "meet.google.com" {
            provider = .googleMeet
            guard let code = path.split(separator: "/").first, !code.isEmpty else { return nil }
            canonicalPath = "/\(code.lowercased())"
        } else if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            provider = .zoom
            guard !path.isEmpty, path != "/" else { return nil }
            canonicalPath = path
        } else if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com") {
            provider = .teams
            guard !path.isEmpty, path != "/" else { return nil }
            canonicalPath = path
        } else if host == "web.whatsapp.com" {
            provider = .whatsApp
            // WhatsApp Web does not expose a durable call id. This is still a
            // distinct approved source and is never used to fuzzily match an
            // arbitrary calendar event.
            canonicalPath = path == "/" ? "/call" : path
        } else if host == "meet.jit.si" || host.hasSuffix(".jitsi.org") {
            provider = .jitsi
            guard !path.isEmpty, path != "/" else { return nil }
            canonicalPath = path
        } else if host == "whereby.com" || host.hasSuffix(".whereby.com") {
            provider = .whereby
            guard !path.isEmpty, path != "/" else { return nil }
            canonicalPath = path
        } else if customDomains.contains(where: { domainMatches(host, approved: $0) }) {
            provider = .custom
            canonicalPath = path
        } else {
            return nil
        }
        return CallIdentity(provider: provider, normalizedURL: "https://\(host)\(canonicalPath)")
    }

    static func zoomDesktop(processIdentifier: Int32) -> CallIdentity {
        CallIdentity(provider: .zoomDesktop, normalizedURL: "zoom-desktop://\(processIdentifier)")
    }

    private static func normalizedPath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let components = decoded.split(separator: "/").map { String($0) }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func domainMatches(_ host: String, approved raw: String) -> Bool {
        let approved = raw.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        return !approved.isEmpty && (host == approved || host.hasSuffix(".\(approved)"))
    }
}

enum CallLaunchType: String, Codable, Hashable {
    case opened
    case ended
    case tabClosed = "tab-closed"
}

struct CallLaunch: Codable, Hashable {
    var version: Int
    var type: CallLaunchType
    var tabID: Int?
    var url: String
    var title: String?
    var detectedAt: Date

    func identity(customDomains: [String] = AppPreferences.customCallDomains) -> CallIdentity? {
        guard let value = URL(string: url) else { return nil }
        return CallIdentity.make(url: value, customDomains: customDomains)
    }
}

enum CapturePrompt: Equatable {
    case matched(event: UnifiedEvent, launch: CallLaunch)
    case unmatched(launch: CallLaunch)
}

enum CallEventMatcher {
    /// Only exact identities match. Time merely prevents a stale calendar item
    /// with the same recurring URL from being selected days later.
    static func match(_ identity: CallIdentity, in events: [UnifiedEvent],
                      detectedAt: Date, calendar: Calendar = .current) -> UnifiedEvent? {
        let nearby = events.filter { event in
            guard let url = event.meetingURL,
                  let eventIdentity = CallIdentity.make(url: URL(string: url) ?? URL(fileURLWithPath: "/")),
                  eventIdentity == identity else { return false }
            return event.startTs.addingTimeInterval(-6 * 60 * 60) <= detectedAt
                && event.endTs.addingTimeInterval(2 * 60 * 60) >= detectedAt
        }
        return nearby.min { abs($0.startTs.timeIntervalSince(detectedAt)) < abs($1.startTs.timeIntervalSince(detectedAt)) }
    }
}

/// Keeps URL changes, repeated extension messages, and a dismissed prompt from
/// producing a stack of dialogs for the same tab/call.
final class CallPromptDebouncer {
    private var seen: [String: Date] = [:]
    private let interval: TimeInterval

    init(interval: TimeInterval = 90) { self.interval = interval }

    func shouldPrompt(identity: CallIdentity, tabID: Int?, now: Date = Date()) -> Bool {
        purge(now: now)
        let value = key(identity, tabID)
        guard seen[value] == nil else { return false }
        seen[value] = now
        return true
    }

    func end(identity: CallIdentity, tabID: Int?) { seen.removeValue(forKey: key(identity, tabID)) }

    private func purge(now: Date) { seen = seen.filter { now.timeIntervalSince($0.value) < interval } }
    private func key(_ identity: CallIdentity, _ tabID: Int?) -> String { "\(identity.key)|\(tabID.map(String.init) ?? "process")" }
}

/// Hall-e-only event. It is stored locally and deliberately never goes through
/// Google Calendar APIs or the sync replacement path.
struct LocalCaptureEvent: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var identityKey: String
    var provider: String
    var title: String
    var startTs: Date
    var endTs: Date
    var notePath: String?
    var createdAt: Date

    static let databaseTableName = "local_capture_event"
    enum Columns {
        static let startTs = Column(CodingKeys.startTs)
        static let endTs = Column(CodingKeys.endTs)
    }

    init(identity: CallIdentity, title: String?, startedAt: Date = Date()) {
        id = UUID().uuidString
        identityKey = identity.key
        provider = identity.provider.rawValue
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (cleaned?.isEmpty == false ? cleaned! : "\(identity.provider.displayName) call")
        startTs = startedAt
        endTs = startedAt.addingTimeInterval(60 * 60)
        notePath = nil
        createdAt = startedAt
    }

    var unifiedEvent: UnifiedEvent {
        UnifiedEvent(dedupKey: "local:\(id)", title: title, startTs: startTs, endTs: endTs,
                     isAllDay: false, status: "confirmed", effectiveResponse: nil,
                     meetingURL: nil, location: nil, descriptionText: nil, htmlLink: nil,
                     organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                     winnerAccountEmail: "", projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
    }
}

actor LocalCaptureEventStore {
    static let shared = LocalCaptureEventStore()

    func create(identity: CallIdentity, title: String?, at date: Date = Date()) async throws -> LocalCaptureEvent {
        let event = LocalCaptureEvent(identity: identity, title: title, startedAt: date)
        try await AppDatabase.shared.dbQueue.write { db in try event.insert(db) }
        return event
    }

    func updateNote(id: String, notePath: String?) async {
        try? await AppDatabase.shared.dbQueue.write { db in
            guard var event = try LocalCaptureEvent.fetchOne(db, key: id) else { return }
            event.notePath = notePath
            try event.update(db)
        }
    }

    func finish(id: String, at date: Date = Date()) async {
        try? await AppDatabase.shared.dbQueue.write { db in
            guard var event = try LocalCaptureEvent.fetchOne(db, key: id) else { return }
            event.endTs = max(event.startTs, date)
            try event.update(db)
        }
    }
}
