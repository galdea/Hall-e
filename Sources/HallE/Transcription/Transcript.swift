import Foundation

struct TranscriptSegment: Codable, Hashable {
    var start: TimeInterval      // offset from recording start (chunk offset applied)
    var duration: TimeInterval
    var text: String
    var track: String            // "mic" | "system"
}

struct Transcript: Codable {
    var sessionID: UUID
    var localeUsed: String
    var segments: [TranscriptSegment]
    var status: TranscriptStatus
    var source: String           // "sfspeech-on-device"

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }
}
