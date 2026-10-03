import Foundation
import CryptoKit

enum BriefingOwnerKind: String, Codable, Hashable { case knownPerson, explicitName, unassigned }

struct BriefingEvidence: Codable, Hashable {
    var utteranceIndex: Int
    var start: TimeInterval
    var end: TimeInterval
    var excerpt: String
}

struct BriefingItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var detail: String?
    var ownerKind: BriefingOwnerKind?
    var ownerName: String?
    var explicitDate: String?
    var priority: Int
    var confidence: Double
    var evidence: [BriefingEvidence]
}

struct MeetingBriefing: Codable, Hashable {
    static let schema = "halle.briefing.v1"
    var schemaVersion: String
    var headline: String
    var objectives: [BriefingItem]
    var tasks: [BriefingItem]
    var decisions: [BriefingItem]
    var risks: [BriefingItem]
    var openQuestions: [BriefingItem]
    var milestones: [BriefingItem]
    var confidence: Double
    var transcriptHash: String
    var promptVersion: String
    var model: String
    var generatedAt: String
}

enum BriefingValidationError: Error, LocalizedError {
    case invalidSchema, transcriptMismatch, invalidEvidence, inventedOwner, inventedDate
    var errorDescription: String? {
        switch self {
        case .invalidSchema: "The report agent returned an unsupported briefing schema."
        case .transcriptMismatch: "The report agent referenced a different transcript revision."
        case .invalidEvidence: "One or more report claims have invalid transcript evidence."
        case .inventedOwner: "The report assigned a task owner without valid evidence."
        case .inventedDate: "The report assigned a date without valid evidence."
        }
    }
}

enum MeetingBriefingValidator {
    static func validate(_ briefing: MeetingBriefing, transcript: Transcript) throws {
        guard briefing.schemaVersion == MeetingBriefing.schema else { throw BriefingValidationError.invalidSchema }
        guard briefing.transcriptHash == transcript.contentHash else { throw BriefingValidationError.transcriptMismatch }
        guard briefing.confidence.isFinite, (0...1).contains(briefing.confidence) else { throw BriefingValidationError.invalidEvidence }
        let all = briefing.objectives + briefing.tasks + briefing.decisions + briefing.risks + briefing.openQuestions + briefing.milestones
        guard Set(all.map(\.id)).count == all.count, all.allSatisfy({ !$0.id.isEmpty }) else {
            throw BriefingValidationError.invalidEvidence
        }
        for item in all {
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.confidence.isFinite, (0...1).contains(item.confidence),
                  !item.evidence.isEmpty, item.evidence.allSatisfy({ evidence in
                guard evidence.utteranceIndex >= 0 && evidence.utteranceIndex < transcript.segments.count,
                      evidence.start.isFinite, evidence.end.isFinite, evidence.start >= 0,
                      evidence.end >= evidence.start else { return false }
                let segment = transcript.segments[evidence.utteranceIndex]
                return segment.start.isFinite && segment.duration.isFinite && segment.duration >= 0
                    && evidence.start >= segment.start - 0.25
                    && evidence.end <= segment.start + segment.duration + 0.25
                    && TextNormalizer.containsPhrase(segment.text, evidence.excerpt)
            }) else { throw BriefingValidationError.invalidEvidence }
        }
        for task in briefing.tasks {
            if task.ownerKind == nil || task.ownerKind == .unassigned {
                guard task.ownerName == nil || task.ownerName?.isEmpty == true else { throw BriefingValidationError.inventedOwner }
            } else {
                guard let owner = task.ownerName?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty,
                      task.evidence.contains(where: { TextNormalizer.containsPhrase($0.excerpt, owner) }) else {
                    throw BriefingValidationError.inventedOwner
                }
            }
            if let date = task.explicitDate, !date.isEmpty,
               !task.evidence.contains(where: { TextNormalizer.containsPhrase($0.excerpt, date) }) {
                throw BriefingValidationError.inventedDate
            }
        }
    }
}

extension Transcript {
    var contentHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data(plainText.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var evidenceTranscript: String {
        segments.enumerated().map { index, segment in
            let speaker = segment.speaker.map { "Speaker \($0)" } ?? segment.track
            return "[u\(index) \(String(format: "%.2f", segment.start))-\(String(format: "%.2f", segment.start + segment.duration)) \(speaker)] \(segment.text)"
        }.joined(separator: "\n")
    }
}

enum BriefingJobStatus: String, Codable, Equatable {
    case queued, running, rendering, completed, retryableFailed = "retryable-failed", actionRequired = "action-required", consentBlocked = "consent-blocked"
}

struct BriefingJob: Codable, Equatable {
    var schemaVersion = 1
    var status: BriefingJobStatus
    var attemptCount: Int
    var transcriptHash: String
    var promptVersion: String
    var model: String
    var lastError: String?
    var startedAt: Date?
    var completedAt: Date?
}
