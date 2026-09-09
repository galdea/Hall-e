import Foundation
import AVFoundation

enum RecordingMixdownService {
    static func makePlaybackMix(for session: RecordingSession) async -> String? {
        guard session.systemAudioFileName != nil,
              FileManager.default.fileExists(atPath: session.micURL.path),
              FileManager.default.fileExists(atPath: session.systemAudioURL.path) else { return nil }

        let outputName = "playback.m4a"
        let outputURL = session.folderURL.appendingPathComponent(outputName)
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let composition = AVMutableComposition()
            let micAsset = AVURLAsset(url: session.micURL)
            let systemAsset = AVURLAsset(url: session.systemAudioURL)
            guard let micSource = try await micAsset.loadTracks(withMediaType: .audio).first,
                  let systemSource = try await systemAsset.loadTracks(withMediaType: .audio).first,
                  let micTrack = composition.addMutableTrack(withMediaType: .audio,
                                                              preferredTrackID: kCMPersistentTrackID_Invalid),
                  let systemTrack = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return nil }

            let micDuration = try await micAsset.load(.duration)
            let systemDuration = try await systemAsset.load(.duration)
            try micTrack.insertTimeRange(CMTimeRange(start: .zero, duration: micDuration),
                                         of: micSource, at: .zero)
            // Align against when the mic actually began capturing, not the
            // session timestamp (stamped before the permission prompt).
            let offsetSeconds = session.timelineOffset(for: "system")
            try systemTrack.insertTimeRange(CMTimeRange(start: .zero, duration: systemDuration),
                                            of: systemSource,
                                            at: CMTime(seconds: offsetSeconds, preferredTimescale: 600))

            guard let exporter = AVAssetExportSession(asset: composition,
                                                       presetName: AVAssetExportPresetAppleM4A) else { return nil }
            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a
            await exporter.export()
            guard exporter.status == .completed else {
                Log.rec.error("recording mixdown failed: \(exporter.error?.localizedDescription ?? "unknown", privacy: .public)")
                return nil
            }
            return outputName
        } catch {
            Log.rec.error("recording mixdown failed: \(error, privacy: .public)")
            return nil
        }
    }
}
