import Foundation
import AVFoundation
import Observation

/// Always-visible mic recording, started manually or by the opt-in calendar scheduler.
@MainActor
@Observable
final class RecordingService: NSObject {
    static let shared = RecordingService()

    private(set) var state: RecordingState = .idle {
        didSet { NotificationCenter.default.post(name: .halleRecordingChanged, object: nil) }
    }
    private(set) var currentSession: RecordingSession?
    private(set) var elapsed: TimeInterval = 0
    private(set) var noticeText: String?
    private(set) var silencePromptVisible = false
    private(set) var scheduledEndPromptVisible = false

    private var recorder: AVAudioRecorder?
    private var systemRecorder: AnyObject?   // SystemAudioRecorder (macOS 14.2+)
    private var timer: Timer?
    private var onFinish: ((RecordingSession) -> Void)?
    private var lifecycleState: RecordingLifecycleState?
    private var lifecyclePolicy: RecordingLifecyclePolicy {
        var policy = RecordingLifecyclePolicy()
        if AppPreferences.stopRecordingAtScheduledEnd { policy.endPromptTimeout = 0 }
        return policy
    }

    var isRecording: Bool { if case .recording = state { return true }; return false }

    /// Microphone TCC status.
    var micAuthorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    func requestMicAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Begin recording mic audio for `event`. `onFinish` fires after stop with the
    /// finalized session (e.g. to kick off transcription).
    func start(for event: UnifiedEvent, notePath: String?,
               sourceKind: RecordingSourceKind = .calendarMeeting,
               onFinish: @escaping (RecordingSession) -> Void) async {
        if case .failed = state { state = .idle }
        guard case .idle = state else { return }
        state = .preparing
        self.onFinish = onFinish

        guard await requestMicAccess() else {
            fail("Microphone access denied. Enable it in System Settings → Privacy → Microphone.")
            return
        }

        var session = RecordingSession(event: event, notePath: notePath, sourceKind: sourceKind)
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
                fail("Could not start the recorder."); return
            }
            self.recorder = recorder
            session.micStartedAt = Date()
            session.state = .recording
            session.save()
            currentSession = session
            lifecycleState = RecordingLifecycleState(startedAt: session.startedAt,
                                                      scheduledEndAt: session.scheduledEndAt)
            noticeText = nil
            silencePromptVisible = false
            scheduledEndPromptVisible = false
            state = .recording
            startTimer()
            Log.rec.info("recording started for \(event.title, privacy: .public)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Records mic plus a best-effort per-app system-audio track. Permissions and
    /// app audio routing are allowed to fail without losing the mic recording.
    func startCall(for event: UnifiedEvent, notePath: String?,
                   sourceKind: RecordingSourceKind,
                   onFinish: @escaping (RecordingSession) -> Void) async {
        await start(for: event, notePath: notePath, sourceKind: sourceKind, onFinish: onFinish)
        guard isRecording, let session = currentSession else { return }
        guard let bundleID = Self.targetBundleID(for: sourceKind) else { return }
        if #available(macOS 14.2, *) {
            let rec = SystemAudioRecorder()
            do {
                try rec.start(targetBundleID: bundleID, to: session.systemAudioURL)
                systemRecorder = rec
                currentSession?.systemAudioFileName = "system.m4a"
                currentSession?.systemAudioStartedAt = Date()
                currentSession?.audioCaptureNotice = nil
                currentSession?.save()
                Log.rec.info("system-audio tap started for \(bundleID, privacy: .public)")
            } catch {
                setMicOnlyNotice("System audio for this call was unavailable; Hall-e is recording your microphone only.")
                Log.rec.error("system-audio tap failed, recording mic only: \(error, privacy: .public)")
            }
        } else {
            setMicOnlyNotice("System audio requires macOS 14.2 or later; Hall-e is recording your microphone only.")
        }
    }

    /// Compatibility entry point used by the existing WhatsApp menu action.
    func startCall(for event: UnifiedEvent, notePath: String?, onFinish: @escaping (RecordingSession) -> Void) async {
        await startCall(for: event, notePath: notePath, sourceKind: .whatsAppCall, onFinish: onFinish)
    }

    func attachCall(identityKey: String, localCaptureEventID: String?) {
        guard var session = currentSession else { return }
        session.callIdentityKey = identityKey
        session.localCaptureEventID = localCaptureEventID
        session.save()
        currentSession = session
    }

    func stop() {
        stop(reason: .manual)
    }

    func stop(reason: RecordingStopReason) {
        guard isRecording else { return }
        currentSession?.stopReason = reason
        currentSession?.save()
        state = .stopping
        stopSystemRecorder()
        recorder?.stop()
        timer?.invalidate(); timer = nil
    }

    func extendScheduledEnd(by interval: TimeInterval = 5 * 60) {
        guard isRecording else { return }
        lifecycleState?.extend(by: interval)
        currentSession?.scheduledEndAt = lifecycleState?.scheduledEndAt
        currentSession?.save()
        scheduledEndPromptVisible = false
        noticeText = "Recording extended by 5 minutes."
    }

    func keepRecordingAfterSilence() {
        lifecycleState?.keepAfterSilence()
        silencePromptVisible = false
        noticeText = nil
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
                r.updateMeters()
                var power = r.averagePower(forChannel: 0)
                if #available(macOS 14.2, *), let system = self.systemRecorder as? SystemAudioRecorder {
                    power = max(power, system.currentPowerDB())
                }
                let sourceActive: Bool?
                if let sourceKind = self.currentSession?.sourceKind,
                   let bundleID = Self.targetBundleID(for: sourceKind), #available(macOS 14.2, *) {
                    let processes = SystemAudioRecorder.processObjects(forBundleID: bundleID)
                    sourceActive = processes.contains {
                        SystemAudioRecorder.isRunningInput($0) || SystemAudioRecorder.isRunningOutput($0)
                    }
                } else {
                    sourceActive = nil
                }
                let actions = self.lifecycleState?.observe(now: Date(), audioPowerDB: power,
                                                           sourceActive: sourceActive,
                                                           policy: self.lifecyclePolicy) ?? []
                self.handle(actions)
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
        if session.stopReason == nil { session.stopReason = success ? .recorderFinished : .recorderFailed }
        session.state = success ? .completed : .failed("Recorder finished unsuccessfully")
        session.save()
        currentSession = session
        state = success ? .completed : .failed("recording failed")
        recorder = nil
        lifecycleState = nil
        noticeText = nil
        silencePromptVisible = false
        scheduledEndPromptVisible = false
        if success { onFinish?(session) }
        onFinish = nil
        // Return to idle so the next recording can start.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if case .completed = self.state { self.state = .idle }
            self.currentSession = nil
        }
    }

    private func fail(_ message: String) {
        stopSystemRecorder()
        recorder?.stop()
        recorder = nil
        timer?.invalidate(); timer = nil
        if var session = currentSession {
            session.endedAt = Date()
            session.stopReason = .recorderFailed
            session.state = .failed(message)
            session.save()
            currentSession = session
        }
        lifecycleState = nil
        onFinish = nil
        noticeText = nil
        silencePromptVisible = false
        scheduledEndPromptVisible = false
        state = .failed(message)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if case .failed = self.state { self.state = .idle; self.currentSession = nil }
        }
    }

    private func handle(_ actions: [RecordingLifecycleAction]) {
        for action in actions {
            switch action {
            case .promptForSilence:
                silencePromptVisible = true
                noticeText = "No voice detected for 20 seconds. Stop recording?"
                NotificationScheduler.shared.postRecordingPrompt(.silence)
            case .promptForScheduledEnd:
                scheduledEndPromptVisible = true
                noticeText = "The scheduled meeting has ended. Stop or extend 5 minutes."
                NotificationScheduler.shared.postRecordingPrompt(.scheduledEnd)
            case .stop(let reason):
                stop(reason: reason)
            }
        }
    }

    private func setMicOnlyNotice(_ notice: String) {
        guard var session = currentSession else { return }
        session.audioCaptureNotice = notice
        session.save()
        currentSession = session
        noticeText = notice
    }

    static func targetBundleID(for source: RecordingSourceKind) -> String? {
        switch source {
        case .whatsAppCall: "net.whatsapp.WhatsApp"
        case .chromeCall: "com.google.Chrome"
        case .zoomCall: "us.zoom.xos"
        case .calendarMeeting, .manual: nil
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
        Task { @MainActor in self.fail(error?.localizedDescription ?? "encode error") }
    }
}
