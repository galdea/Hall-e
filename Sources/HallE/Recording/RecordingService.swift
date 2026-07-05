import Foundation
import AVFoundation
import Observation

/// Manual, always-visible mic recording. Never starts on its own — only via an
/// explicit user action. System-audio capture is a later phase (Core Audio taps).
@MainActor
@Observable
final class RecordingService: NSObject {
    static let shared = RecordingService()

    private(set) var state: RecordingState = .idle {
        didSet { NotificationCenter.default.post(name: .halleRecordingChanged, object: nil) }
    }
    private(set) var currentSession: RecordingSession?
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var systemRecorder: AnyObject?   // SystemAudioRecorder (macOS 14.2+)
    private var timer: Timer?
    private var onFinish: ((RecordingSession) -> Void)?

    var isRecording: Bool { if case .recording = state { return true }; return false }

    /// Microphone TCC status.
    var micAuthorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func requestMicAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Begin recording mic audio for `event`. `onFinish` fires after stop with the
    /// finalized session (e.g. to kick off transcription).
    func start(for event: UnifiedEvent, notePath: String?, onFinish: @escaping (RecordingSession) -> Void) async {
        guard case .idle = state else { return }
        state = .preparing
        self.onFinish = onFinish

        guard await requestMicAccess() else {
            state = .failed("Microphone access denied. Enable it in System Settings → Privacy → Microphone.")
            return
        }

        var session = RecordingSession(event: event, notePath: notePath)
        session.state = .preparing
        do {
            try FileManager.default.createDirectory(at: session.folderURL, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: session.micURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                state = .failed("Could not start the recorder."); return
            }
            self.recorder = recorder
            session.state = .recording
            session.save()
            currentSession = session
            state = .recording
            startTimer()
            Log.rec.info("recording started for \(event.title, privacy: .public)")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Record a WhatsApp call: mic (always) + a best-effort Core Audio tap on
    /// WhatsApp's output (the remote party). If the tap fails, recording continues
    /// mic-only and the note is still produced.
    func startCall(for event: UnifiedEvent, notePath: String?, onFinish: @escaping (RecordingSession) -> Void) async {
        await start(for: event, notePath: notePath, onFinish: onFinish)
        guard isRecording, let session = currentSession else { return }
        if #available(macOS 14.2, *) {
            let rec = SystemAudioRecorder()
            do {
                try rec.start(targetBundleID: "net.whatsapp.WhatsApp", to: session.systemAudioURL)
                systemRecorder = rec
                currentSession?.systemAudioFileName = "system.m4a"
                currentSession?.save()
                Log.rec.info("system-audio tap started (WhatsApp)")
            } catch {
                Log.rec.error("system-audio tap failed, recording mic only: \(error, privacy: .public)")
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        state = .stopping
        stopSystemRecorder()
        recorder?.stop()
        timer?.invalidate(); timer = nil
    }

    private func stopSystemRecorder() {
        if #available(macOS 14.2, *) { (systemRecorder as? SystemAudioRecorder)?.stop() }
        systemRecorder = nil
    }

    // MARK: - Internals

    private func startTimer() {
        elapsed = 0
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                self.elapsed = r.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func finalize(success: Bool) {
        timer?.invalidate(); timer = nil
        stopSystemRecorder()
        guard var session = currentSession else { state = .idle; return }
        session.endedAt = Date()
        session.state = success ? .completed : .failed("Recorder finished unsuccessfully")
        session.save()
        currentSession = session
        state = success ? .completed : .failed("recording failed")
        if success { onFinish?(session) }
        // Return to idle so the next recording can start.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if case .completed = self.state { self.state = .idle }
            self.currentSession = nil
        }
    }
}

extension Notification.Name {
    static let halleRecordingChanged = Notification.Name("cl.gabriel.hall-e.recordingChanged")
}

extension RecordingService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in self.finalize(success: flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.state = .failed(error?.localizedDescription ?? "encode error") }
    }
}
