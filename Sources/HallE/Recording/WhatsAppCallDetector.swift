import Foundation
import AppKit

/// Best-effort auto-prompt: polls whether WhatsApp is using the mic and, on a
/// rising edge, raises the "Record this call?" consent prompt. NOT authoritative
/// — it also fires for voice-messages and misses WhatsApp Web, so it only ever
/// PROMPTS (via the same consent alert), never auto-records. No TCC needed.
@available(macOS 14.2, *)
@MainActor
final class WhatsAppCallDetector {
    static let shared = WhatsAppCallDetector()
    private var timer: Timer?
    private var wasUsingMic = false

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard AppPreferences.autoPromptWhatsAppCalls else { return }
        // Don't prompt while a recording is already in progress.
        if RecordingService.shared.isRecording { wasUsingMic = true; return }

        let usingMic = SystemAudioRecorder.processObject(forBundleID: "net.whatsapp.WhatsApp")
            .map { SystemAudioRecorder.isRunningInput($0) } ?? false

        if usingMic && !wasUsingMic {
            // Rising edge → offer to record (consent handled inside the hook).
            Features.current.startCallRecording()
        }
        wasUsingMic = usingMic
    }
}
