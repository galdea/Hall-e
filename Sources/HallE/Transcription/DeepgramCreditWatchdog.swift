import Foundation

/// Checks the Deepgram balance on launch and daily thereafter. This is the
/// proactive half of credit alerting and is deliberately best-effort: with a
/// transcription-only key the balance is unreadable, so it logs and stays quiet.
/// `DeepgramCreditMonitor.handle` on a failed request is the guaranteed path.
@MainActor final class DeepgramCreditWatchdog {
    static let shared = DeepgramCreditWatchdog()
    private var timer: Timer?
    private let interval: TimeInterval = 24 * 60 * 60

    private init() {}

    func start() {
        guard timer == nil else { return }
        Task { await DeepgramCreditMonitor.checkBalance() }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await DeepgramCreditMonitor.checkBalance() }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
