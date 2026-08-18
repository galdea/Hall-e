import Foundation

enum TranscriptionEnginePreference: String, CaseIterable, Codable, Identifiable {
    case auto
    case deepgram
    case whisperKit = "whisperkit"
    case sfSpeech = "sfspeech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .deepgram: "Deepgram Nova-3"
        case .whisperKit: "WhisperKit (local AI)"
        case .sfSpeech: "Apple Speech"
        }
    }
}

enum TranscriptionLanguagePreference: String, CaseIterable, Codable, Identifiable {
    case auto
    case spanish = "es"
    case english = "en"
    case portuguese = "pt"
    case french = "fr"
    case german = "de"
    case italian = "it"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto-detect"
        case .spanish: "Spanish"
        case .english: "English"
        case .portuguese: "Portuguese"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        }
    }

    /// WhisperKit accepts the two-letter Whisper language code. `nil` asks it
    /// to detect the language for each decoding window.
    var whisperCode: String? { self == .auto ? nil : rawValue }

    /// Apple Speech cannot auto-detect reliably without falling through to an
    /// unrelated language. Auto is deliberately Spanish for Hall-e's default
    /// audience and is still constrained to Spanish locales.
    var sfSpeechCode: String { self == .auto ? "es" : rawValue }
}

enum SolvedTranscriptionEngine: Equatable {
    case deepgram
    case whisperKit(model: String)
    case whisperCLI(model: String, language: String?)
    case sfSpeech(language: String)
    case whisperKitUnavailable
}

enum TranscriptionEngineResolver {
    static func resolve(
        preference: TranscriptionEnginePreference,
        language: TranscriptionLanguagePreference,
        model: String,
        modelDownloaded: Bool,
        deepgramReady: Bool = AppPreferences.allowCloudAudioTranscription && KeychainStore.exists(account: KeychainStore.deepgramTranscriptionAccount),
        whisperCLIAvailable: Bool = WhisperCLITranscriptionProvider.isAvailable
    ) -> SolvedTranscriptionEngine {
        switch preference {
        case .deepgram:
            return .deepgram
        case .whisperKit:
            return modelDownloaded ? .whisperKit(model: model) : .whisperKitUnavailable
        case .sfSpeech:
            return .sfSpeech(language: language.sfSpeechCode)
        case .auto:
            // Automatic means “use Hall-e's primary local engine”. Prefer the
            // installed Whisper CLI because it is the proven local runtime on
            // this Mac, then use WhisperKit when it is available. It must not
            // silently switch to Apple's recognizer when the model is missing:
            // that produced completed-looking but unusable transcripts after a
            // meeting. The caller keeps the durable job retryable until the
            // model is prepared (or the person explicitly chooses Apple Speech).
            if deepgramReady { return .deepgram }
            if whisperCLIAvailable {
                return .whisperCLI(model: WhisperCLITranscriptionProvider.model,
                                   language: language.whisperCode)
            }
            return modelDownloaded ? .whisperKit(model: model) : .whisperKitUnavailable
        }
    }
}
