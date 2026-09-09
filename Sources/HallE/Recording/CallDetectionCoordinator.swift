import AppKit
import Foundation

/// Receives local browser signals and best-effort desktop app activity. It is
/// deliberately a *prompt* coordinator: none of these signals can start a
/// recording until the person using Hall-e chooses an explicit consent action.
@MainActor
final class CallDetectionCoordinator {
    static let shared = CallDetectionCoordinator()

    private let debouncer = CallPromptDebouncer()
    private var timer: Timer?
    private var activeBrowserCalls: [CallIdentity: Set<Int>] = [:]
    private var activeDesktopCalls: Set<CallIdentity> = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        // Drain immediately so a native host message received while Hall-e was
        // closed is handled as soon as the app is launched.
        poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeDesktopCalls.removeAll()
        activeBrowserCalls.removeAll()
    }

    /// Kept internal so model-level tests and debug tools can feed a validated
    /// launch without needing Chrome, native messaging, or a running app.
    func handle(_ launch: CallLaunch) {
        guard let identity = launch.identity() else { return }
        switch launch.type {
        case .opened:
            guard AppPreferences.enabledCallSources.contains("chrome") else { return }
            activeBrowserCalls[identity, default: []].insert(launch.tabID ?? -1)
            if RecordingService.shared.confirmBrowserCall(identity: identity) { return }
            offerCapture(identity: identity, launch: launch)
        case .ended, .tabClosed:
            activeBrowserCalls[identity]?.remove(launch.tabID ?? -1)
            debouncer.end(identity: identity, tabID: launch.tabID)
            if activeBrowserCalls[identity]?.isEmpty != false {
                activeBrowserCalls.removeValue(forKey: identity)
                stopIfRecording(identity: identity)
            }
        }
    }

    func browserIdentity(for event: UnifiedEvent) -> CallIdentity? {
        guard let link = event.meetingURL, let url = URL(string: link),
              let identity = CallIdentity.make(url: url), activeBrowserCalls[identity]?.isEmpty == false else { return nil }
        return identity
    }

    private func poll() {
        for launch in BrowserCallMessageQueue.drain() { handle(launch) }
        guard #available(macOS 14.2, *) else { return }
        pollDesktop(bundleID: "net.whatsapp.WhatsApp", provider: .whatsApp, preference: "whatsapp")
        pollDesktop(bundleID: "us.zoom.xos", provider: .zoomDesktop, preference: "zoom")
    }

    @available(macOS 14.2, *)
    private func pollDesktop(bundleID: String, provider: CallProvider, preference: String) {
        guard AppPreferences.enabledCallSources.contains(preference) else { return }
        let activeProcesses = SystemAudioRecorder.processObjects(forBundleID: bundleID).filter {
            // A running input is not perfect call classification (WhatsApp voice
            // notes can look alike), but it never records automatically.
            SystemAudioRecorder.isRunningInput($0)
        }
        let currentlyActive = Set(activeProcesses.map {
            CallIdentity(provider: provider, normalizedURL: "\(provider.rawValue)://\($0)")
        })
        let relevantExisting = activeDesktopCalls.filter { $0.provider == provider }
        for ended in relevantExisting.subtracting(currentlyActive) {
            debouncer.end(identity: ended, tabID: nil)
            // Audio-process inactivity can mean mute or a quiet participant.
            // The recording's voice-silence countdown owns this decision.
        }
        activeDesktopCalls.subtract(relevantExisting)
        activeDesktopCalls.formUnion(currentlyActive)

        for identity in currentlyActive.subtracting(relevantExisting) {
            let launch = CallLaunch(version: 1, type: .opened, tabID: nil,
                                    url: identity.normalizedURL,
                                    title: "\(provider.displayName) call", detectedAt: Date())
            offerCapture(identity: identity, launch: launch)
        }
    }

    private func offerCapture(identity: CallIdentity, launch: CallLaunch) {
        guard !RecordingService.shared.isRecording,
              debouncer.shouldPrompt(identity: identity, tabID: launch.tabID) else { return }
        if let event = CallEventMatcher.match(identity, in: AppState.shared.agenda, detectedAt: launch.detectedAt) {
            presentMatchedPrompt(event: event, identity: identity, launch: launch)
        } else {
            presentUnmatchedPrompt(identity: identity, launch: launch)
        }
    }

    private func presentMatchedPrompt(event: UnifiedEvent, identity: CallIdentity, launch: CallLaunch) {
        let alert = NSAlert()
        alert.messageText = "Record this \(identity.provider.displayName) call?"
        alert.informativeText = "This call matches “\(event.title)”. Hall-e records locally and will try to capture your microphone plus this app’s audio. Tell all participants before recording. Opening the meeting through Hall-e lets its normal join flow offer capture next time."
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Open Hall-e")
        alert.addButton(withTitle: "Dismiss")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            RecordingCoordinator.startDetectedCall(for: event, identity: identity)
        case .alertSecondButtonReturn:
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .halleShowPopover, object: nil)
        default:
            break
        }
    }

    private func presentUnmatchedPrompt(identity: CallIdentity, launch: CallLaunch) {
        let alert = NSAlert()
        alert.messageText = "Add this \(identity.provider.displayName) call to Hall-e?"
        alert.informativeText = "Hall-e will create a local-only calendar entry and vault note; it will not create or change a Google Calendar event. Recording stays on this Mac. Tell all participants before recording."
        alert.addButton(withTitle: "Add to Hall-e & Record")
        alert.addButton(withTitle: "Dismiss")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let local = try await LocalCaptureEventStore.shared.create(identity: identity, title: launch.title,
                                                                            at: launch.detectedAt)
                RecordingCoordinator.startDetectedCall(for: local.unifiedEvent, identity: identity, localEvent: local)
            } catch {
                Log.rec.error("could not create local call event: \(error, privacy: .public)")
                presentLocalEventFailure(error)
            }
        }
    }

    private func stopIfRecording(identity: CallIdentity) {
        guard RecordingService.shared.currentSession?.callIdentityKey == identity.key else { return }
        RecordingService.shared.stop(reason: .sourceEnded)
    }

    private func presentLocalEventFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hall-e could not add this call"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
