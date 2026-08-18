import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class RecordingPlaybackService: NSObject {
    static let shared = RecordingPlaybackService()

    private(set) var activeSessionID: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ session: RecordingSession) {
        if activeSessionID == session.id, let player {
            player.isPlaying ? pause() : resume()
            return
        }
        play(session)
    }

    func play(_ session: RecordingSession) {
        stop(resetSelection: false)
        do {
            let player = try AVAudioPlayer(contentsOf: session.playbackURL)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else { throw PlaybackError.couldNotStart }
            self.player = player
            activeSessionID = session.id
            duration = player.duration
            currentTime = player.currentTime
            isPlaying = true
            errorMessage = nil
            startTimer()
        } catch {
            activeSessionID = session.id
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func resume() {
        guard let player else { return }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else { return }
        isPlaying = true
        startTimer()
    }

    func seek(to value: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, value), player.duration)
        currentTime = player.currentTime
    }

    func stop(resetSelection: Bool = true) {
        player?.stop()
        player = nil
        timer?.invalidate(); timer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if resetSelection { activeSessionID = nil }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private enum PlaybackError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "Could not start recording playback." }
    }
}

extension RecordingPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.timer?.invalidate(); self.timer = nil
            self.isPlaying = false
            self.currentTime = 0
            player.currentTime = 0
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.errorMessage = error?.localizedDescription ?? "Recording playback failed."
            self.stop(resetSelection: false)
        }
    }
}
