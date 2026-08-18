import Foundation

/// Pluggable transcription engine. Local (on-device) is the default; cloud or
/// Additional engines can be added later behind the same protocol.
protocol TranscriptionProvider: Sendable {
    /// Preferred locale identifiers, in fallback order.
    func transcribe(fileURL: URL, sessionID: UUID, track: String) async throws -> Transcript
}

enum TranscriptionError: Error, LocalizedError {
    case notAuthorized
    case noLocaleAvailable
    case engineUnavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition permission was denied."
        case .noLocaleAvailable: "No on-device speech model is installed for the selected language. Hall-e will not use another language as a fallback."
        case .engineUnavailable(let m): "Speech recognizer unavailable: \(m)"
        case .failed(let m): "Transcription failed: \(m)"
        }
    }
}
