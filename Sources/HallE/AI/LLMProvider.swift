import Foundation

// MARK: - Task inputs / outputs

struct MeetingContext {
    var title: String
    var project: String?
    var date: String
    var attendees: [String]
}

struct ActionItem: Codable, Hashable {
    var task: String
    var owner: String?
    var due_date: String?
    var project: String?
    var confidence: Double?
}

struct MeetingInsights: Codable, Hashable {
    var cleanedTranscript: String?
    var summary: String
    var decisions: [String]
    var actionItems: [ActionItem]
    var followUps: [String]
    var risks: [String]
    var confidence: Double?
    var source: String?

    enum CodingKeys: String, CodingKey {
        case cleanedTranscript = "cleaned_transcript"
        case summary, decisions
        case actionItems = "action_items"
        case followUps = "follow_ups"
        case risks, confidence, source
    }

    init(cleanedTranscript: String? = nil, summary: String = "", decisions: [String] = [],
         actionItems: [ActionItem] = [], followUps: [String] = [], risks: [String] = [],
         confidence: Double? = nil, source: String? = nil) {
        self.cleanedTranscript = cleanedTranscript; self.summary = summary
        self.decisions = decisions; self.actionItems = actionItems
        self.followUps = followUps; self.risks = risks
        self.confidence = confidence; self.source = source
    }
}

struct BriefEventInput {
    var time: String
    var title: String
    var project: String?
}

struct ConnectionTestResult {
    var ok: Bool
    var latencyMs: Int
    var detail: String
}

enum LLMError: Error, LocalizedError {
    case featureDisabled
    case notConfigured(String)
    case http(Int, String)
    case network(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .featureDisabled: "AI features are turned off."
        case .notConfigured(let m): "AI is not configured: \(m)."
        case .http(let c, let m): "LLM HTTP \(c): \(m)"
        case .network(let m): "Network error: \(m)"
        case .invalidResponse(let m): "LLM returned an unusable response: \(m)"
        }
    }
}

/// Uniform interface over LLM providers. Adapters funnel task methods into a
/// single `complete` call; task logic (prompts, parsing) is shared.
protocol LLMProvider: Sendable {
    var providerName: String { get }
    func testConnection() async throws -> ConnectionTestResult
    func classifyMeeting(_ input: ClassificationInput, candidates: [String]) async throws -> MeetingClassificationResult
    func summarizeTranscript(_ transcript: String, context: MeetingContext) async throws -> String
    func extractActionItems(_ transcript: String, context: MeetingContext) async throws -> [ActionItem]
    func generateDailyBrief(_ events: [BriefEventInput]) async throws -> String
    func extractMeetingInsights(_ transcript: String, context: MeetingContext) async throws -> MeetingInsights
    /// One short subject line for naming a recording, or nil when the transcript
    /// does not support one. Never throws its way into a made-up title.
    func describeMeetingTopic(_ transcript: String, context: MeetingContext) async throws -> String?
    func generateProjectSnapshot(context: ProjectAssistantContext) async throws -> ProjectSnapshotPayload
    func answerProjectQuestion(_ question: String, context: ProjectAssistantContext) async throws -> ProjectAssistantAnswer
}

extension LLMProvider {
    /// Compatibility fallback for providers that have not implemented a single
    /// structured request yet. Chat-style providers override this with one call.
    func extractMeetingInsights(_ transcript: String, context: MeetingContext) async throws -> MeetingInsights {
        let summary = try await summarizeTranscript(transcript, context: context)
        let actions = try await extractActionItems(transcript, context: context)
        return MeetingInsights(summary: summary, actionItems: actions, source: providerName)
    }

    /// Providers that cannot name a recording simply do not; the caller keeps
    /// the calendar title rather than failing the recording.
    func describeMeetingTopic(_ transcript: String, context: MeetingContext) async throws -> String? {
        nil
    }

    func generateProjectSnapshot(context: ProjectAssistantContext) async throws -> ProjectSnapshotPayload {
        throw LLMError.featureDisabled
    }

    func answerProjectQuestion(_ question: String, context: ProjectAssistantContext) async throws -> ProjectAssistantAnswer {
        throw LLMError.featureDisabled
    }
}
