import Foundation

/// Builds the active provider from config + Keychain. Returns DisabledLLMProvider
/// whenever AI is off or the config is incomplete.
enum LLMProviderFactory {
    static func make(config: LLMProviderConfig = .load()) -> LLMProvider {
        guard config.useAI, config.kind != .disabled else { return DisabledLLMProvider() }
        let key = config.kind.needsAPIKey ? KeychainStore.get(account: config.keychainAccount) : nil
        if config.kind.needsAPIKey && (key == nil || key!.isEmpty) { return DisabledLLMProvider() }
        if config.model.isEmpty { return DisabledLLMProvider() }

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
