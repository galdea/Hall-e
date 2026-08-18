import Foundation

/// Builds the active provider from config + Keychain. Returns DisabledLLMProvider
/// whenever AI is off or the config is incomplete.
enum LLMProviderFactory {
    static func make(config: LLMProviderConfig = .load()) -> LLMProvider {
        guard config.useAI, config.kind != .disabled else { return DisabledLLMProvider() }
        let key = config.kind.needsAPIKey ? config.resolveAPIKey() : nil
        if config.kind.needsAPIKey && (key == nil || key!.isEmpty) {
            Log.ai.warning("AI is enabled but no API key is stored for \(config.kind.rawValue, privacy: .public); AI features are inactive")
            return DisabledLLMProvider(reason: "No API key saved for \(config.kind.displayName)")
        }
        if config.model.isEmpty {
            Log.ai.warning("AI is enabled but no model is set for \(config.kind.rawValue, privacy: .public); AI features are inactive")
            return DisabledLLMProvider(reason: "No model set for \(config.kind.displayName)")
        }

        switch config.kind {
        case .anthropic:
            return AnthropicProvider(config: config, apiKey: key)
        case .gemini:
            return GeminiProvider(config: config, apiKey: key)
        case .openAI, .openRouter, .ollama, .lmStudio, .custom:
            return OpenAICompatibleProvider(config: config, apiKey: key)
        case .disabled:
            return DisabledLLMProvider()
        }
    }

    /// A provider built directly for a "test connection" (uses a provided key,
    /// bypassing the useAI gate).
    static func makeForTest(config: LLMProviderConfig, apiKey: String?) -> LLMProvider {
        switch config.kind {
        case .anthropic: AnthropicProvider(config: config, apiKey: apiKey)
        case .gemini: GeminiProvider(config: config, apiKey: apiKey)
        case .disabled: DisabledLLMProvider()
        default: OpenAICompatibleProvider(config: config, apiKey: apiKey)
        }
    }
}
