import Foundation

/// Pure routing inputs: no Keychain, preferences, network, or spend side effects.
enum CloudFallbackPolicy {
    struct Availability: Equatable {
        var deepgramConfigured = false
        var deepgramConsented = false
        var speechmaticsConfigured = false
        var speechmaticsConsented = false

        var deepgramAvailable: Bool { deepgramConfigured && deepgramConsented }
        var speechmaticsAvailable: Bool { speechmaticsConfigured && speechmaticsConsented }
    }

    /// An accepted Speechmatics job can be retrieved safely. An upload without
    /// a definite outcome must be reviewed before any new provider submission.
    static func requiresReview(_ checkpoint: CloudTranscriptionJob?) -> Bool {
        guard let checkpoint else { return false }
        if checkpoint.provider == .speechmatics, checkpoint.providerJobID != nil { return false }
        return checkpoint.state == .ambiguousBilling
            || checkpoint.state == .uploading
            || checkpoint.state == .awaitingResponse
            || checkpoint.phase == .submitting
            || checkpoint.phase == .ambiguousSubmission
    }

    /// Called only after Deepgram's own credential failover has finished.
    /// Never infer credit exhaustion from an arbitrary error's text or status.
    static func fallback(preference: TranscriptionEnginePreference,
                         failedEngine: SolvedTranscriptionEngine,
                         error: Error,
                         availability: Availability,
                         checkpoint: CloudTranscriptionJob? = nil) -> SolvedTranscriptionEngine? {
        guard preference == .auto, failedEngine == .deepgram,
              availability.speechmaticsAvailable,
              checkpoint?.provider != .speechmatics,
              !requiresReview(checkpoint),
              let error = error as? DeepgramError,
              case .creditExhausted = error else { return nil }
        return .speechmatics
    }
}
