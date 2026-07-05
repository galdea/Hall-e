import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case disabled, openAI, openRouter, ollama, lmStudio, anthropic, gemini, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled: "Disabled"
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama (local)"
        case .lmStudio: "LM Studio (local)"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    /// Default base URL for the kind (editable for local/custom).
    var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom, .disabled: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .openRouter: "openai/gpt-4o-mini"
        case .ollama: "llama3.1"
        case .lmStudio: "local-model"
        case .anthropic: "claude-3-5-haiku-latest"
        case .gemini: "gemini-2.5-flash"
        case .custom, .disabled: ""
        }
    }

    /// Whether to send `response_format: json_object` (some local servers 400 on it).
    var supportsJSONMode: Bool {
        switch self { case .openAI, .openRouter, .gemini: true; default: false }
    }

    var needsAPIKey: Bool {
        switch self { case .ollama, .lmStudio, .disabled: false; default: true }
    }

    var baseURLEditable: Bool {
        switch self { case .ollama, .lmStudio, .custom: true; default: false }
    }
}

/// LLM configuration. Deliberately contains NO API key — keys live only in the
/// Keychain, keyed by `keychainAccount`.
struct LLMProviderConfig: Codable, Equatable {
    var kind: ProviderKind = .disabled
    var baseURL: String = ""
    var model: String = ""
    var temperature: Double = 0.2
    var maxTokens: Int = 2048
    var timeoutSeconds: Double = 60
    var useAI: Bool = false
    var allowCloudTranscriptProcessing: Bool = false
    var preferLocal: Bool = true

    var keychainAccount: String {
        let host = URL(string: baseURL)?.host ?? kind.rawValue
        return KeychainStore.llmKeyAccount(providerKind: kind.rawValue, host: host)
    }

    static func load() -> LLMProviderConfig {
        AppPreferences.codable(LLMProviderConfig.self, forKey: AppPreferences.llmProviderConfigKey) ?? LLMProviderConfig()
    }
    func save() { AppPreferences.setCodable(self, forKey: AppPreferences.llmProviderConfigKey) }
}
