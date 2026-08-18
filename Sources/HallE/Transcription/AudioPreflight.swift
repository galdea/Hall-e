import Foundation
import AVFoundation

enum AudioPreflight {
    enum Error: LocalizedError {
        case missing
        case unreadable
        case noAudioTrack
        case empty

        var errorDescription: String? {
            switch self {
            case .missing: "The audio file is missing."
            case .unreadable: "The audio file could not be decoded."
            case .noAudioTrack: "The file does not contain an audio track."
            case .empty: "The audio file is empty."
            }
        }
    }

    /// Validate before asking Speech to read a file. This gives people an
    /// actionable error instead of a generic recognizer failure and ensures the
    /// chunker only receives decodable audio.
    static func validate(_ fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw Error.missing }
        guard let file = try? AVAudioFile(forReading: fileURL) else { throw Error.unreadable }
        guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw Error.empty }
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Error.noAudioTrack }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw Error.empty }
    }
}
