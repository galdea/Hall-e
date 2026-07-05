import Foundation

/// Providers that expose a single chat-style `complete` call get all the task
/// methods (classify / summarize / action items / brief / test) for free.
protocol ChatCompletionProvider: LLMProvider {
    func complete(system: String, user: String, expectJSON: Bool, maxTokens: Int?) async throws -> String
}

/// Wrapper for the action-items JSON payload (top-level so it can be used inside
/// the generic protocol-extension method).
private struct ActionItemsWrapper: Codable { let action_items: [ActionItem] }

extension ChatCompletionProvider {
    func testConnection() async throws -> ConnectionTestResult {
        let start = DispatchTime.now()
        let reply = try await complete(system: "You are a health check.",
                                       user: "Reply with the single word: ok", expectJSON: false, maxTokens: 5)
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        return ConnectionTestResult(ok: !reply.isEmpty, latencyMs: ms, detail: reply.prefix(40).description)
    }

    func classifyMeeting(_ input: ClassificationInput, candidates: [String]) async throws -> MeetingClassificationResult {
        let (sys, usr) = PromptTemplateStore.classification(input: input, candidates: candidates)
        let reply = try await complete(system: sys, user: usr, expectJSON: true, maxTokens: nil)
        guard let result = JSONExtractor.decode(MeetingClassificationResult.self, from: reply) else {
            throw LLMError.invalidResponse("classification JSON")
        }
        return result
    }

    func summarizeTranscript(_ transcript: String, context: MeetingContext) async throws -> String {
        let (sys, usr) = PromptTemplateStore.summary(transcript: transcript, context: context)
        return try await complete(system: sys, user: usr, expectJSON: false, maxTokens: nil)
    }

    func extractActionItems(_ transcript: String, context: MeetingContext) async throws -> [ActionItem] {
        let (sys, usr) = PromptTemplateStore.actionItems(transcript: transcript, context: context)
        let reply = try await complete(system: sys, user: usr, expectJSON: true, maxTokens: nil)
        return JSONExtractor.decode(ActionItemsWrapper.self, from: reply)?.action_items ?? []
    }

    func generateDailyBrief(_ events: [BriefEventInput]) async throws -> String {
        let (sys, usr) = PromptTemplateStore.dailyBrief(events: events)
        return try await complete(system: sys, user: usr, expectJSON: false, maxTokens: nil)
    }
}
