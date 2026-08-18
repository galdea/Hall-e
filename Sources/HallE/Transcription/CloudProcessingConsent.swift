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

struct CloudTranscriptionJob: Codable, Equatable {
    var schemaVersion = 1
    var state: CloudTranscriptionState
    var requestFingerprint: String
    var estimatedCostUSD: Double
    var requestID: String?
    var retryAfter: Date?
    var lastHTTPStatus: Int?
    var lastErrorCode: String?
    var updatedAt: Date
}
