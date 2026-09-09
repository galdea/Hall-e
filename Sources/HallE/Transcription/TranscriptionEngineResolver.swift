import Foundation

enum TranscriptionEnginePreference: String, CaseIterable, Codable, Identifiable {
    /// Prefer configured, consented Deepgram, with Speechmatics as the cloud fallback.
    case auto
    case deepgram
    case speechmatics
    case sfSpeech = "sfspeech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic (Deepgram → Speechmatics)"
        case .deepgram: "Deepgram Nova-3"
        case .speechmatics: "Speechmatics Melia 1 (fallback)"
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

    /// Apple Speech cannot auto-detect reliably without falling through to an
    /// unrelated language. Auto is deliberately Spanish for Hall-e's default
    /// audience and is still constrained to Spanish locales.
    var sfSpeechCode: String { self == .auto ? "es" : rawValue }
}

enum SolvedTranscriptionEngine: Equatable {
    case deepgram
    case speechmatics
    case sfSpeech(language: String)
}

enum TranscriptionEngineResolver {
    /// Availability is injected so routing never reads credentials or preferences.
    /// With neither cloud available, Deepgram reports the missing setup/consent.
    static func resolve(preference: TranscriptionEnginePreference,
                        language: TranscriptionLanguagePreference,
                        availability: CloudFallbackPolicy.Availability = .init(),
                        checkpoint: CloudTranscriptionJob? = nil) -> SolvedTranscriptionEngine {
        // Resuming an accepted remote job is not a new engine selection.
        if checkpoint?.provider == .speechmatics, checkpoint?.providerJobID != nil {
            return .speechmatics
        }
        switch preference {
        case .auto:
            // Keep retries on their chosen provider, including legacy Deepgram
            // checkpoints. Configuration changes must not turn an unknown
            // upload outcome or a spend failure into a provider switch.
            if let checkpoint {
                // Recording before setup must remain usable after connecting
                // Speechmatics alone. These checkpoints prove no upload began.
                let setupBlocked = checkpoint.state == .consentBlocked
                    || checkpoint.lastErrorCode == "missing_api_key"
                if checkpoint.provider != .speechmatics, setupBlocked,
                   !availability.deepgramAvailable, availability.speechmaticsAvailable {
                    return .speechmatics
                }
                return checkpoint.provider == .speechmatics ? .speechmatics : .deepgram
            }
            return availability.deepgramAvailable || !availability.speechmaticsAvailable
                ? .deepgram : .speechmatics
        case .deepgram:
            return .deepgram
        case .speechmatics:
            return .speechmatics
        case .sfSpeech:
            return .sfSpeech(language: language.sfSpeechCode)
        }
    }
}
