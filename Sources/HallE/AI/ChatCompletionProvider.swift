import Foundation

/// Providers that expose a single chat-style `complete` call get all the task
/// methods (classify / summarize / action items / brief / test) for free.
protocol ChatCompletionProvider: LLMProvider {
    func complete(system: String, user: String, expectJSON: Bool, maxTokens: Int?) async throws -> String
}

/// Wrapper for the action-items JSON payload (top-level so it can be used inside
/// the generic protocol-extension method).
private struct ActionItemsWrapper: Codable { let action_items: [ActionItem] }
private struct ProjectSnapshotDraft: Codable {
    let summary: String
    let status: String
    let health: String
    let goals: [String]
    let decisions: [String]
    let blockers: [String]
    let risks: [String]
    let next_steps: [String]
    let open_questions: [String]
    let agenda: [String]
    let citation_ids: [String]
    let confidence: Double?
}
private struct ProjectAnswerDraft: Codable {
    let answer: String
    let citation_ids: [String]
    let suggested_updates: [String]
}

extension ChatCompletionProvider {
    func generateProjectSnapshot(context: ProjectAssistantContext) async throws -> ProjectSnapshotPayload {
        let (system, user) = PromptTemplateStore.projectSnapshot(context: context)
        let reply = try await complete(system: system, user: user, expectJSON: true, maxTokens: nil)
        guard let draft = JSONExtractor.decode(ProjectSnapshotDraft.self, from: reply) else {
            throw LLMError.invalidResponse("project snapshot JSON")
        }
        let citations = Self.resolve(draft.citation_ids, from: context.citations)
        guard !citations.isEmpty || context.citations.isEmpty else {
            throw LLMError.invalidResponse("project snapshot citations")
        }
        return ProjectSnapshotPayload(summary: draft.summary, status: draft.status, health: draft.health,
                                      goals: draft.goals, decisions: draft.decisions,
                                      blockers: draft.blockers, risks: draft.risks,
                                      nextSteps: draft.next_steps, openQuestions: draft.open_questions,
                                      agenda: draft.agenda, citations: citations,
                                      confidence: draft.confidence)
    }

    func answerProjectQuestion(_ question: String, context: ProjectAssistantContext) async throws -> ProjectAssistantAnswer {
        let (system, user) = PromptTemplateStore.projectQuestion(question, context: context)
        let reply = try await complete(system: system, user: user, expectJSON: true, maxTokens: nil)
        guard let draft = JSONExtractor.decode(ProjectAnswerDraft.self, from: reply) else {
            throw LLMError.invalidResponse("project assistant JSON")
        }
        let citations = Self.resolve(draft.citation_ids, from: context.citations)
        guard !citations.isEmpty || context.citations.isEmpty else {
            throw LLMError.invalidResponse("project assistant citations")
        }
        return ProjectAssistantAnswer(answer: draft.answer,
                                      citations: citations,
                                      suggestedUpdates: draft.suggested_updates)
    }

    func extractMeetingInsights(_ transcript: String, context: MeetingContext) async throws -> MeetingInsights {
        let (sys, usr) = PromptTemplateStore.meetingInsights(transcript: transcript, context: context)
        let reply = try await complete(system: sys, user: usr, expectJSON: true, maxTokens: nil)
        guard let value = JSONExtractor.decode(MeetingInsights.self, from: reply) else {
            throw LLMError.invalidResponse("meeting insights JSON")
        }
        return value
    }

    func describeMeetingTopic(_ transcript: String, context: MeetingContext) async throws -> String? {
        let (system, user) = PromptTemplateStore.recordingTopic(transcript: transcript, context: context)
        // A subject line is a few tokens; capping keeps a chatty model from
        // returning a paragraph that would only be thrown away.
        let reply = try await complete(system: system, user: user, expectJSON: false, maxTokens: 60)
        guard let topic = RecordingFolderName.cleanTopic(reply),
              topic.caseInsensitiveCompare("unknown") != .orderedSame else { return nil }
        return topic
    }

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
        guard let wrapper = JSONExtractor.decode(ActionItemsWrapper.self, from: reply) else {
            Log.ai.error("action-items reply was not decodable JSON; returning none")
            return []
        }
        return wrapper.action_items
    }

    func generateDailyBrief(_ events: [BriefEventInput]) async throws -> String {
        let (sys, usr) = PromptTemplateStore.dailyBrief(events: events)
        return try await complete(system: sys, user: usr, expectJSON: false, maxTokens: nil)
    }

    private static func resolve(_ ids: [String], from citations: [ProjectCitation]) -> [ProjectCitation] {
        let requested = Set(ids)
        return citations.filter { requested.contains($0.id) }
    }
}
