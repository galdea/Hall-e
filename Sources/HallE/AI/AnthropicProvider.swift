import Foundation

/// Anthropic Messages API adapter. Same task methods via ChatCompletionProvider;
/// only the wire format differs (x-api-key, anthropic-version, system top-level).
struct AnthropicProvider: ChatCompletionProvider {
    let config: LLMProviderConfig
    let apiKey: String?

    var providerName: String { "Anthropic" }

    func complete(system: String, user: String, expectJSON: Bool, maxTokens: Int?) async throws -> String {
        var base = config.baseURL.isEmpty ? config.kind.defaultBaseURL : config.baseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/messages") else { throw LLMError.notConfigured("invalid base URL") }
        guard let apiKey, !apiKey.isEmpty else { throw LLMError.notConfigured("Anthropic API key required") }

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens ?? config.maxTokens,
            "temperature": config.temperature,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw LLMError.network(error.localizedDescription) }

        guard let http = response as? HTTPURLResponse else { throw LLMError.network("no HTTP response") }
        guard http.statusCode == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? (String(data: data, encoding: .utf8)?.prefix(200)).map(String.init) ?? ""
            throw LLMError.http(http.statusCode, msg)
        }
        // content is an array of blocks; concatenate the text blocks.
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse("missing content blocks")
        }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw LLMError.invalidResponse("no text blocks") }
        return text
    }
}

/// Gemini via Google's OpenAI-compatible endpoint (one wire format to maintain).
struct GeminiProvider: ChatCompletionProvider {
    let config: LLMProviderConfig
    let apiKey: String?
    var providerName: String { "Google Gemini" }

    private var inner: OpenAICompatibleProvider { OpenAICompatibleProvider(config: config, apiKey: apiKey) }

    func complete(system: String, user: String, expectJSON: Bool, maxTokens: Int?) async throws -> String {
        try await inner.complete(system: system, user: user, expectJSON: expectJSON, maxTokens: maxTokens)
    }
}

/// Default when AI is off or unconfigured: every call fails with .featureDisabled,
/// which callers treat as "skip enrichment".
struct DisabledLLMProvider: LLMProvider {
    var providerName: String { "Disabled" }
    func testConnection() async throws -> ConnectionTestResult { throw LLMError.featureDisabled }
    func classifyMeeting(_ input: ClassificationInput, candidates: [String]) async throws -> MeetingClassificationResult { throw LLMError.featureDisabled }
    func summarizeTranscript(_ transcript: String, context: MeetingContext) async throws -> String { throw LLMError.featureDisabled }
    func extractActionItems(_ transcript: String, context: MeetingContext) async throws -> [ActionItem] { throw LLMError.featureDisabled }
    func generateDailyBrief(_ events: [BriefEventInput]) async throws -> String { throw LLMError.featureDisabled }
}
