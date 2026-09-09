import Foundation

enum TranscriptionEnginePreference: String, CaseIterable, Codable, Identifiable {
    /// Use a connected, consented cloud provider; otherwise stay on device.
    case auto
    case deepgram
    case speechmatics
    case sfSpeech = "sfspeech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: PublicUICopy.text("Automatic (local or connected cloud)", "Automático (local o nube conectada)")
        case .deepgram: "Deepgram Nova-3"
        case .speechmatics: "Speechmatics Melia 1 (fallback)"
        case .sfSpeech: PublicUICopy.text("On this Mac (Apple Speech)", "En este Mac (Apple Speech)")
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
        case .auto: PublicUICopy.text("Automatic (Mac language for local speech)", "Automático (idioma del Mac para voz local)")
        case .spanish: PublicUICopy.text("Spanish", "Español")
        case .english: PublicUICopy.text("English", "Inglés")
        case .portuguese: PublicUICopy.text("Portuguese", "Portugués")
        case .french: PublicUICopy.text("French", "Francés")
        case .german: PublicUICopy.text("German", "Alemán")
        case .italian: PublicUICopy.text("Italian", "Italiano")
        }
    }

    /// Apple Speech needs an explicit language. Cloud providers can auto-detect.
    var sfSpeechCode: String {
        self == .auto ? Self.localLanguage(preferredLanguages: Locale.preferredLanguages) : rawValue
    }

    static func localLanguage(preferredLanguages: [String]) -> String {
        for identifier in preferredLanguages {
            let code = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
            if let language = Self(rawValue: code.lowercased()), language != .auto { return language.rawValue }
        }
        // Preserve an unsupported Mac language so setup explains that a model
        // is unavailable instead of silently transcribing in unrelated English.
        let first = preferredLanguages.first?.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init)?.lowercased()
        return first.flatMap { $0.isEmpty ? nil : $0 } ?? "en"
    }
}

enum SolvedTranscriptionEngine: Equatable {
    case deepgram
    case speechmatics
    case sfSpeech(language: String)
}

enum TranscriptionEngineResolver {
    /// Availability is injected so routing never reads credentials or preferences.
    /// A fresh installation needs no account or API key for local transcription.
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
                if setupBlocked, !CloudFallbackPolicy.requiresReview(checkpoint),
                   !availability.deepgramAvailable, !availability.speechmaticsAvailable {
                    return .sfSpeech(language: language.sfSpeechCode)
                }
                if checkpoint.provider != .speechmatics, setupBlocked,
                   !availability.deepgramAvailable, availability.speechmaticsAvailable {
                    return .speechmatics
                }
                return checkpoint.provider == .speechmatics ? .speechmatics : .deepgram
            }
            if availability.deepgramAvailable { return .deepgram }
            if availability.speechmaticsAvailable { return .speechmatics }
            return .sfSpeech(language: language.sfSpeechCode)
        case .deepgram:
            return .deepgram
        case .speechmatics:
            return .speechmatics
        case .sfSpeech:
            return .sfSpeech(language: language.sfSpeechCode)
        }
    }
}
