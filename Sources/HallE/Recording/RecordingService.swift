import Foundation
import AVFoundation
import Observation
import AppKit

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
    private(set) var activePromptID: UUID?
    private(set) var silenceSecondsRemaining: Int?

    private var recorder: AVAudioRecorder?
    private var systemRecorder: AnyObject?   // SystemAudioRecorder (macOS 14.2+)
    private var timer: Timer?
    private var onFinish: ((RecordingSession) -> Void)?
    private var lifecycleState: RecordingLifecycleState?
    private var micVoiceMonitor: MicrophoneVoiceMonitor?
    private var captureEpoch = Date()
    private var captureUptime: TimeInterval = 0
    private var lastRecorderTime: TimeInterval = 0
    private var callCaptureIdentityVerified = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationCompletion: (() -> Void)?
    private var lifecycleNow: Date { captureEpoch.addingTimeInterval(ProcessInfo.processInfo.systemUptime - captureUptime) }
    private var lifecyclePolicy: RecordingLifecyclePolicy {
        var policy = RecordingLifecyclePolicy()
        if AppPreferences.stopRecordingAtScheduledEnd { policy.endPromptTimeout = 0 }
        policy.silenceEnabled = AppPreferences.silenceDetectionEnabled
        policy.silenceAutoStop = AppPreferences.silenceAutoStopEnabled
        policy.silenceDuration = AppPreferences.recordingSilenceSeconds
        policy.silencePromptTimeout = AppPreferences.recordingConfirmationSeconds
        return policy
    }

    var isRecording: Bool { if case .recording = state { return true }; return false }

    override init() {
        super.init()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    self.lifecycleState?.resetSilenceObservation()
                    self.micVoiceMonitor?.invalidate()
                    if #available(macOS 14.2, *) { (self.systemRecorder as? SystemAudioRecorder)?.invalidateVoiceActivity() }
                    self.clearPrompt()
                    self.noticeText = self.currentSession?.audioCaptureNotice
                }
            })
        }
    }

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
            currentSession = session
            try session.persist()
            captureEpoch = Date()
            captureUptime = ProcessInfo.processInfo.systemUptime
            lastRecorderTime = 0
            lifecycleState = RecordingLifecycleState(startedAt: captureEpoch,
                                                      scheduledEndAt: nil)
            let voiceMonitor = MicrophoneVoiceMonitor()
            do { try voiceMonitor.start(); micVoiceMonitor = voiceMonitor }
            catch { voiceMonitor.stop(); micVoiceMonitor = nil }
            activePromptID = nil
            silenceSecondsRemaining = nil
            noticeText = nil
            silencePromptVisible = false
            scheduledEndPromptVisible = false
            state = .recording
            callCaptureIdentityVerified = event.meetingURL == nil
            if sourceKind == .calendarMeeting, event.meetingURL != nil {
                if let identity = CallDetectionCoordinator.shared.browserIdentity(for: event) {
                    confirmBrowserCall(identity: identity)
                } else {
                    setMicOnlyNotice("Meeting app audio is not verified; microphone only. Automatic silence stopping is paused to protect remote speech.")
                }
            }
            startTimer()
            Log.rec.info("recording started for \(event.title, privacy: .private)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Records mic plus a best-effort per-app system-audio track. Permissions and
    /// app audio routing are allowed to fail without losing the mic recording.
    @discardableResult
    func startCall(for event: UnifiedEvent, notePath: String?,
                   sourceKind: RecordingSourceKind,
                   targetBundleID: String? = nil,
                   onFinish: @escaping (RecordingSession) -> Void) async -> UUID? {
        switch state { case .idle, .failed: break; default: return nil }
        await start(for: event, notePath: notePath, sourceKind: sourceKind, onFinish: onFinish)
        guard isRecording, let session = currentSession else { return nil }
        guard let bundleID = targetBundleID ?? Self.targetBundleID(for: sourceKind) else { return session.id }
        currentSession?.capturedAppBundleID = bundleID
        currentSession?.save()
        startSystemCapture(bundleID: bundleID, session: session)
        callCaptureIdentityVerified = systemRecorder != nil
        return session.id
    }

    var canRetryMeetingAudio: Bool {
        isRecording && systemRecorder == nil && currentSession?.capturedAppBundleID != nil
    }

    func retryMeetingAudio() {
        guard canRetryMeetingAudio, let session = currentSession, let bundleID = session.capturedAppBundleID else { return }
        startSystemCapture(bundleID: bundleID, session: session)
        callCaptureIdentityVerified = systemRecorder != nil
        if callCaptureIdentityVerified { noticeText = nil }
    }

    private func startSystemCapture(bundleID: String, session: RecordingSession) {
        if #available(macOS 14.2, *) {
            let rec = SystemAudioRecorder()
            do {
                try rec.start(targetBundleID: bundleID, to: session.systemAudioURL)
                systemRecorder = rec
                currentSession?.systemAudioFileName = "system.m4a"
                currentSession?.systemAudioStartedAt = Date()
                currentSession?.capturedAppBundleID = bundleID
                currentSession?.audioCaptureNotice = nil
                currentSession?.save()
                Log.rec.info("system-audio tap started for \(bundleID, privacy: .public)")
            } catch {
                setMicOnlyNotice(PublicUICopy.text("Meeting app audio is unavailable: recording your microphone only. Join the call, check macOS audio recording permission, then retry meeting audio.", "El audio de la app no está disponible: solo se graba tu micrófono. Entra a la llamada, revisa el permiso de grabación de audio en macOS y reintenta."))
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

    func attachCall(sessionID: UUID, identityKey: String, localCaptureEventID: String?) {
        guard var session = currentSession, session.id == sessionID, isRecording else { return }
        session.callIdentityKey = identityKey
        session.localCaptureEventID = localCaptureEventID
        session.save()
        currentSession = session
    }

    @discardableResult
    func confirmBrowserCall(identity: CallIdentity) -> Bool {
        guard isRecording, let session = currentSession, session.sourceKind == .calendarMeeting,
              let link = session.eventSnapshot?.meetingURL, let url = URL(string: link),
              CallIdentity.make(url: url) == identity else { return false }
        if systemRecorder == nil { startSystemCapture(bundleID: "com.google.Chrome", session: session) }
        callCaptureIdentityVerified = systemRecorder != nil
        if callCaptureIdentityVerified {
            attachCall(sessionID: session.id, identityKey: identity.key, localCaptureEventID: nil)
            noticeText = nil
        }
        return true
    }

    func stop() {
        stop(reason: .manual)
    }

    func stop(reason: RecordingStopReason) {
        guard isRecording else { return }
        currentSession?.stopReason = reason
        currentSession?.save()
        state = .stopping
        clearPrompt()
        micVoiceMonitor?.stop(); micVoiceMonitor = nil
        stopSystemRecorder()
        recorder?.stop()
        timer?.invalidate(); timer = nil
    }

    func extendScheduledEnd(by interval: TimeInterval = 5 * 60) {
        guard isRecording else { return }
        lifecycleState?.extend(by: interval, now: lifecycleNow)
        currentSession?.scheduledEndAt = lifecycleState?.scheduledEndAt
        currentSession?.save()
        clearPrompt()
        noticeText = "Recording extended by 5 minutes."
    }

    func keepRecordingAfterSilence() {
        guard isRecording else { return }
        lifecycleState?.keepAfterSilence()
        clearPrompt()
        noticeText = nil
    }

    private func clearPrompt() {
        activePromptID = nil
        silenceSecondsRemaining = nil
        silencePromptVisible = false
        scheduledEndPromptVisible = false
        NotificationScheduler.shared.clearRecordingPrompts()
    }

    /// App termination waits for the recorder's file-finalization callback.
    func finishBeforeTermination(_ completion: @escaping () -> Void) {
        guard isRecording || state == .stopping else { completion(); return }
        terminationCompletion = completion
        if isRecording { stop(reason: .manual) }
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
                guard let self, self.isRecording, let r = self.recorder else { return }
                self.elapsed = r.currentTime
                r.updateMeters()
                var voice = self.micVoiceMonitor?.hasVoice
                var strongAudio = r.peakPower(forChannel: 0) > -35
                if #available(macOS 14.2, *), let system = self.systemRecorder as? SystemAudioRecorder {
                    let remote = system.currentVoiceActivity()
                    voice = voice == true || remote == true ? true : (voice == nil || remote == nil ? nil : false)
                    strongAudio = strongAudio || system.currentPowerDB() > -35
                }
                // Classification uses a multi-second window. New audible input
                // cancels an imminent stop while that window catches up, so a
                // person speaking at the deadline is not cut off.
                if self.silencePromptVisible && strongAudio { voice = true }
                if r.currentTime <= self.lastRecorderTime { voice = nil }
                if !self.callCaptureIdentityVerified { voice = nil }
                self.lastRecorderTime = r.currentTime
                // Calendar end is informational by default. Preserve explicit
                // opt-in hard-stop behavior without letting process inactivity
                // masquerade as the end of a call.
                if AppPreferences.stopRecordingAtScheduledEnd,
                   let end = self.currentSession?.scheduledEndAt, Date() >= end {
                    self.stop(reason: .scheduledEnd); return
                }
                let power: Float = voice.map { $0 ? -20 : -80 } ?? .nan
                let actions = self.lifecycleState?.observe(now: self.lifecycleNow, audioPowerDB: power,
                                                           sourceActive: nil,
                                                           policy: self.lifecyclePolicy) ?? []
                self.handle(actions)
                if !self.silencePromptVisible && AppPreferences.silenceDetectionEnabled && self.elapsed > 5 {
                    self.noticeText = voice == nil
                        ? (self.currentSession?.audioCaptureNotice ?? "Voice detection is unavailable. Automatic silence stopping is paused; recording continues.")
                        : self.currentSession?.audioCaptureNotice
                }
                if self.silencePromptVisible {
                    if AppPreferences.silenceAutoStopEnabled, let prompted = self.lifecycleState?.silencePromptedAt {
                        let remaining = max(0, Int(ceil(self.lifecyclePolicy.silencePromptTimeout - self.lifecycleNow.timeIntervalSince(prompted))))
                        self.silenceSecondsRemaining = remaining
                        self.noticeText = "No voice detected. Recording stops in \(remaining)s."
                    } else {
                        self.silenceSecondsRemaining = nil
                        self.noticeText = "No voice detected. Stop recording or keep going?"
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func finalize(success: Bool) {
        timer?.invalidate(); timer = nil
        stopSystemRecorder()
        micVoiceMonitor?.stop(); micVoiceMonitor = nil
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
        clearPrompt()
        if success { onFinish?(session) }
        onFinish = nil
        let completedSessionID = session.id
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?()
        // Return to idle so the next recording can start.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.currentSession?.id == completedSessionID else { return }
            if case .completed = self.state { self.state = .idle; self.currentSession = nil }
        }
    }

    private func fail(_ message: String) {
        micVoiceMonitor?.stop(); micVoiceMonitor = nil
        clearPrompt()
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
        let failedSessionID = currentSession?.id
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.currentSession?.id == failedSessionID else { return }
            if case .failed = self.state { self.state = .idle; self.currentSession = nil }
        }
    }

    private func handle(_ actions: [RecordingLifecycleAction]) {
        for action in actions {
            switch action {
            case .promptForSilence:
                guard let session = currentSession else { continue }
                let promptID = UUID()
                activePromptID = promptID
                silencePromptVisible = true
                noticeText = "No voice detected. Stop recording?"
                NotificationScheduler.shared.postRecordingPrompt(.silence, sessionID: session.id, promptID: promptID)
            case .cancelSilencePrompt:
                clearPrompt()
                noticeText = currentSession?.audioCaptureNotice
            case .promptForScheduledEnd:
                guard let session = currentSession else { continue }
                let promptID = UUID()
                activePromptID = promptID
                scheduledEndPromptVisible = true
                noticeText = "The scheduled meeting has ended. Stop or extend 5 minutes."
                NotificationScheduler.shared.postRecordingPrompt(.scheduledEnd, sessionID: session.id, promptID: promptID)
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
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.finalize(success: flag)
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            self.fail(error?.localizedDescription ?? "encode error")
        }
    }
}
