import Foundation

/// Pure first-run policy: one permission must never mark everything ready.
struct SetupReadiness {
    var microphoneGranted: Bool
    var speechGranted: Bool
    var localModelAvailable: Bool
    var engine: TranscriptionEnginePreference
    var cloud: CloudFallbackPolicy.Availability

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
        case .deepgram: return cloud.deepgramAvailable
        case .speechmatics: return cloud.speechmaticsAvailable
        case .auto: return cloud.deepgramAvailable || cloud.speechmaticsAvailable || (speechGranted && localModelAvailable)
        }
    }

    var readyToMeet: Bool { microphoneGranted && transcriptionReady }
    static func restoredStep(_ stored: Int) -> Int { min(3, max(0, stored)) }
}
