import Foundation
import CryptoKit

/// Per-account transcript text fetched on demand (ADR 0007, lazy transcripts). It lives beside the
/// calendar cache, in a directory named after the same private partition, with the same permissions.
/// Everything here can be fetched again, so callers may delete it freely.
struct AccountTranscriptCache {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    init(root: URL, origin: URL, userId: String) {
        self.directory = Self.directory(in: root, origin: origin, userId: userId)
    }

    static func directory(in root: URL, origin: URL, userId: String) -> URL {
        root.appendingPathComponent(AccountCalendarCache.partition(origin, userId) + ".transcripts", isDirectory: true)
    }

    /// File name for one recording. Hashed so server IDs never become path components.
    static func name(meetingId: String, recordingId: String) -> String {
        SHA256.hash(data: Data((meetingId.lowercased() + "\u{0}" + recordingId.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined() + ".txt"
    }

    func file(meetingId: String, recordingId: String) -> URL {
        directory.appendingPathComponent(Self.name(meetingId: meetingId, recordingId: recordingId))
    }

    func load(meetingId: String, recordingId: String) -> String? {
        guard let data = try? Data(contentsOf: file(meetingId: meetingId, recordingId: recordingId)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ text: String, meetingId: String, recordingId: String) throws {
        let fm = FileManager.default
        let root = directory.deletingLastPathComponent()
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = file(meetingId: meetingId, recordingId: recordingId)
        try Data(text.utf8).write(to: target, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Keeps only the files for `recordings` (meeting ID, recording ID) and deletes every other file.
    func retain(_ recordings: [(meetingId: String, recordingId: String)]) {
        let keep = Set(recordings.map { Self.name(meetingId: $0.meetingId, recordingId: $0.recordingId) })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// What a transcript row shows while its text is fetched on demand.
enum AccountTranscriptState: Equatable {
    case idle
    case loading
    case loaded(String)
    case failed(String)
}
