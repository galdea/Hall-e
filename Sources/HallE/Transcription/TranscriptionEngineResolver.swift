import Foundation

enum TranscriptionEnginePreference: String, CaseIterable, Codable, Identifiable {
    /// Retained so a preference stored by an older build still decodes. It now
    /// means the same thing as `.deepgram`; there is no local engine left for it
    /// to quietly fall through to, which is exactly why Whisper was removed.
    case auto
    case deepgram
    case sfSpeech = "sfspeech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Automatic (Deepgram)"
        case .deepgram: "Deepgram Nova-3"
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
    case sfSpeech(language: String)
}

enum TranscriptionEngineResolver {
    /// Deepgram is the only automatic engine. When it cannot run — no consent, no
    /// key, no credit — the job fails loudly and stays retryable rather than
    /// producing a worse transcript from some other engine behind Gabriel's back.
    static func resolve(preference: TranscriptionEnginePreference,
                        language: TranscriptionLanguagePreference) -> SolvedTranscriptionEngine {
        switch preference {
        case .auto, .deepgram:
            return .deepgram
        case .sfSpeech:
            return .sfSpeech(language: language.sfSpeechCode)
        }
    }
}
