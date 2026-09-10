import Foundation

/// Pure first-run policy: one permission must never mark everything ready.
struct SetupReadiness {
    var microphoneGranted: Bool
    var speechGranted: Bool
    var localModelAvailable: Bool
    var engine: TranscriptionEnginePreference
    var cloud: CloudFallbackPolicy.Availability
    var deepgramVerified = false
    var speechmaticsVerified = false

    var usesLocalTranscription: Bool {
        switch engine {
        case .sfSpeech: return true
        case .auto: return !cloud.deepgramAvailable && !cloud.speechmaticsAvailable
        case .deepgram, .speechmatics: return false
        }
    }

    var transcriptionReady: Bool {
        switch engine {
        case .sfSpeech: return speechGranted && localModelAvailable
        case .deepgram: return cloud.deepgramAvailable && deepgramVerified
        case .speechmatics: return cloud.speechmaticsAvailable && speechmaticsVerified
        case .auto:
            // Match actual provider precedence. A working local model or backup
            // must not hide an unverified primary selected by Automatic.
            if cloud.deepgramAvailable { return deepgramVerified }
            if cloud.speechmaticsAvailable { return speechmaticsVerified }
            return speechGranted && localModelAvailable
        }
    }

    var readyToMeet: Bool { microphoneGranted && transcriptionReady }
    static func restoredStep(_ stored: Int) -> Int { min(3, max(0, stored)) }
}
