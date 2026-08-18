import Foundation
import AVFoundation

/// Splits a long audio file into overlapping windows so on-device recognition
/// stays reliable. Returns temp files with their start offsets.
enum AudioChunker {
    struct Chunk {
        let index: Int
        let url: URL
        let offset: TimeInterval
    }

    static let windowSeconds: TimeInterval = 240   // 4 min
    static let overlapSeconds: TimeInterval = 2

    /// Export chunks (passthrough m4a). For files ≤ one window, returns the file
    /// itself at offset 0.
    static func chunk(fileURL: URL) async throws -> [Chunk] {
        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > windowSeconds else {
            return [Chunk(index: 0, url: fileURL, offset: 0)]
        }

        var chunks: [Chunk] = []
        var start: TimeInterval = 0
        var index = 0
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        var exported = false
        // A throw mid-loop would otherwise strand already-exported chunk files.
        defer { if !exported { try? FileManager.default.removeItem(at: tmpDir) } }

        while start < duration {
            let end = min(start + windowSeconds, duration)
            let out = tmpDir.appendingPathComponent("chunk-\(index).m4a")
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw TranscriptionError.failed("cannot create export session")
            }
            export.outputURL = out
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600))
            await export.export()
            guard export.status == .completed else {
                throw TranscriptionError.failed(export.error?.localizedDescription ?? "audio chunk export failed")
            }
            chunks.append(Chunk(index: index, url: out, offset: start))
            if end >= duration { break }
            start = end - overlapSeconds
            index += 1
        }
        exported = true
        return chunks
    }

    static func cleanup(_ chunks: [Chunk], original: URL) {
        for c in chunks where c.url != original {
            try? FileManager.default.removeItem(at: c.url.deletingLastPathComponent())
            break
        }
    }
}
