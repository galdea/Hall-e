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

        // Any process in the WhatsApp family using the mic → a call (outgoing or
        // incoming, voice or video) is under way. Checking the whole family (not
        // just the first match) is what makes outgoing/video calls fire reliably.
        let procs = SystemAudioRecorder.processObjects(forBundleID: "net.whatsapp.WhatsApp")
        let usingMic = procs.contains { SystemAudioRecorder.isRunningInput($0) }

        if usingMic && !wasUsingMic {
            // Rising edge → offer to record (consent handled inside the hook).
            Log.app.info("WhatsApp mic-in-use detected → offering to record call")
            Features.current.startCallRecording()
        }
        wasUsingMic = usingMic
    }
}
