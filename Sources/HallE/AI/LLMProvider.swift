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
}
