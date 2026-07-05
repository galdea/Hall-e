import Foundation

/// One adapter for every OpenAI-compatible /chat/completions server: OpenAI,
/// OpenRouter, Ollama, LM Studio, Gemini (compat endpoint), and custom.
/// Task methods come from the ChatCompletionProvider extension.
struct OpenAICompatibleProvider: ChatCompletionProvider {
    let config: LLMProviderConfig
    let apiKey: String?

    var providerName: String { config.kind.displayName }

    func complete(system: String, user: String, expectJSON: Bool, maxTokens: Int?) async throws -> String {
        var base = config.baseURL.isEmpty ? config.kind.defaultBaseURL : config.baseURL
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw LLMError.notConfigured("invalid base URL")
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": config.temperature,
            "max_tokens": maxTokens ?? config.maxTokens,
            "stream": false,
        ]
        if expectJSON && config.kind.supportsJSONMode {
            body["response_format"] = ["type": "json_object"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.invalidResponse("missing choices[0].message.content")
        }
        return content
    }
}
