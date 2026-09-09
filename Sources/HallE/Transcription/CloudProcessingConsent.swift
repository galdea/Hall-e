import Foundation

struct CloudProcessingConsent: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var processor: String
    var purpose: String
    var termsObservedAt: Date
    var grantedAt: Date
    var revokedAt: Date?
    var modelImprovementOptOut: Bool

    var isActive: Bool { version == Self.currentVersion && revokedAt == nil }

    static func grant(processor: String, purpose: String, termsObservedAt: Date = Date(),
                      modelImprovementOptOut: Bool = true) -> Self {
        .init(version: currentVersion, processor: processor, purpose: purpose,
              termsObservedAt: termsObservedAt, grantedAt: Date(), revokedAt: nil,
              modelImprovementOptOut: modelImprovementOptOut)
    }

    mutating func revoke(at date: Date = Date()) { revokedAt = date }
}

enum CloudTranscriptionState: String, Codable, Equatable {
    case queued, uploading, awaitingResponse = "awaiting-response", validating, completed
    case retryableFailure = "retryable-failure"
    case actionRequired = "action-required"
    case ambiguousBilling = "ambiguous-billing"
    case consentBlocked = "consent-blocked"
    case cancelled
}

enum CloudTranscriptionProvider: String, Codable, Equatable {
    case deepgram
    case speechmatics
}

/// Provider-side phase. `CloudTranscriptionState` remains the user-facing job
/// state; this finer checkpoint prevents a Speechmatics create request from
/// being repeated after a crash or lost response.
enum CloudTranscriptionPhase: String, Codable, Equatable {
    case submitting
    case submitted
    case polling
    case retrieving
    case validating
    case completed
    case ambiguousSubmission = "ambiguous-submission"
    case actionRequired = "action-required"
}

struct CloudTranscriptionJob: Codable, Equatable {
    var schemaVersion = 2
    var state: CloudTranscriptionState
    var requestFingerprint: String
    var estimatedCostUSD: Double
    var requestID: String?
    var retryAfter: Date?
    var lastHTTPStatus: Int?
    var lastErrorCode: String?
    var updatedAt: Date
    /// Optional for backward-compatible decoding of pre-provider checkpoints.
    /// A missing provider is the existing Deepgram path.
    var provider: CloudTranscriptionProvider? = nil
    var phase: CloudTranscriptionPhase? = nil
    var providerJobID: String? = nil
    /// Speechmatics job IDs are region-scoped and must be retrieved from the
    /// same endpoint that accepted the upload.
    var providerRegion: String? = nil
}
