import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Operator driver for the Deepgram migration gates. Runs one step and
        // exits without installing the status item or starting a calendar sync:
        // `HALLE_DEEPGRAM_OP=status /Applications/Hall-e.app/Contents/MacOS/Hall-e`
        if let operation = DeepgramMigrationOps.requestedOperation {
            Task { @MainActor in
                await DeepgramMigrationOps.run(operation)
                exit(0)
            }
            return
        }

        // Diagnostic: print WhatsApp/active audio process objects and exit. Reads
        // public properties only (no capture, no permission). Run during a live
        // call: `HALLE_DEBUG_AUDIO_PROCESSES=1 /Applications/Hall-e.app/Contents/MacOS/Hall-e`
        if ProcessInfo.processInfo.environment["HALLE_DEBUG_AUDIO_PROCESSES"] == "1" {
            if #available(macOS 14.2, *) {
                FileHandle.standardOutput.write(Data((SystemAudioRecorder.diagnostics() + "\n").utf8))
            } else {
                FileHandle.standardOutput.write(Data("requires macOS 14.2+\n".utf8))
            }
            exit(0)
        }

        // Diagnostic: actually run the WhatsApp tap for N seconds (default 8) and
        // report captured bytes/frames. This is the path that triggers the
        // "System Audio Recording" permission — run it DURING a live call:
        // `HALLE_DEBUG_CAPTURE_WHATSAPP=8 /Applications/Hall-e.app/Contents/MacOS/Hall-e`
        if let secStr = ProcessInfo.processInfo.environment["HALLE_DEBUG_CAPTURE_WHATSAPP"] {
            let seconds = Double(secStr) ?? 8
            let out = FileHandle.standardOutput
            if #available(macOS 14.2, *) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("halle-whatsapp-test.m4a")
                try? FileManager.default.removeItem(at: url)
                let rec = SystemAudioRecorder()
                do {
                    try rec.start(targetBundleID: "net.whatsapp.WhatsApp", to: url)
                    out.write(Data("capturing WhatsApp for \(seconds)s → \(url.path)\n".utf8))
                    Thread.sleep(forTimeInterval: seconds)
                    rec.stop()
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                    var report = "stopped. file: \(size) bytes"
                    if let f = try? AVAudioFile(forReading: url) {
                        report += ", \(f.length) frames @ \(Int(f.processingFormat.sampleRate))Hz"
                    }
                    report += size > 2000 ? "  → CAPTURED (play the file to hear the other party)\n"
                                          : "  → EMPTY (permission denied, or zero-samples: try during an ACTIVE call)\n"
                    out.write(Data(report.utf8))
                } catch {
                    out.write(Data("capture failed: \(error.localizedDescription)\n".utf8))
                }
            } else {
                out.write(Data("requires macOS 14.2+\n".utf8))
            }
            exit(0)
        }

        Log.app.info("Hall-e launching, bundle \(Bundle.main.bundleIdentifier ?? "nil", privacy: .public)")
        installMainMenu()
        DebugFixtures.loadIfRequested()
        AppState.shared.startObserving()
        NotificationScheduler.shared.configure()
        if AppPreferences.notificationsEnabled && AppPreferences.onboardingCompleted {
            Task { await NotificationScheduler.shared.requestAuthorizationIfNeeded() }
        }
        // Runs before the recovery passes so those see each recording at its
        // final path and re-save it there.
        RecordingLibrary.migrateFlatLayoutOnce()
        RecordingStore.reconcileStaleTranscripts()
        RecordingStore.enqueueLegacyFailuresForRetryOnce()
        RecordingStore.enqueueAppleSpeechFallbacksForRetryOnce()
        RecordingRecovery.reconcileInterruptedCaptures()
        Log.rec.info("transcription recovery startup: \(RecordingStore.queuedSessions().count, privacy: .public) queued job(s)")
        // Deepgram needs no local model, so there is nothing to prepare before
        // queued jobs resume — and no launch path that can start a download.
        Task { @MainActor in
            Log.rec.info("transcription recovery task started")
            await RecordingCoordinator.resumeQueuedJobsWhenIdle()
            Log.rec.info("transcription recovery task finished")
            await MeetingBriefingPipeline.resumeQueuedWhenIdle()
        }
        if ObsidianVaultConfig.load() != nil {
            Features.current = ObsidianFeatureHooks()
            Task { await VaultIndex.shared.reindex() }
        }
        Task { await ProjectSourceImportCoordinator.shared.refreshLinkedCodexSources() }
        statusItemController = StatusItemController()

        if !AppPreferences.onboardingCompleted,
           ProcessInfo.processInfo.environment["HALLE_DEBUG_FIXTURES"] != "1" {
            OnboardingWindowController.shared.show()
        }

        NotificationCenter.default.addObserver(
            forName: .halleManualRefresh, object: nil, queue: .main
        ) { _ in
            Task { await SyncCoordinator.shared.syncAll() }
        }
        NotificationCenter.default.addObserver(
            forName: .halleShowPopover, object: nil, queue: .main
        ) { [weak self] _ in
            self?.statusItemController?.showPopover()
        }
        NotificationCenter.default.addObserver(
            forName: .halleProjectKnowledgeChanged, object: nil, queue: .main
        ) { note in
            if let projectId = note.userInfo?["projectId"] as? String {
                Task { await ProjectIntelligenceService.shared.scheduleRefresh(projectId: projectId) }
            } else {
                Task { await ProjectIntelligenceService.shared.scheduleRefreshAll() }
            }
        }

        // Periodic + event-based syncing (timer, wake, network). Skipped under
        // fixtures so directly-inserted sample data isn't rebuilt away.
        if ProcessInfo.processInfo.environment["HALLE_DEBUG_FIXTURES"] != "1" {
            RefreshScheduler.shared.start()
            CallDetectionCoordinator.shared.start()
            DeepgramCreditWatchdog.shared.start()
        }

        // Debug hooks for headless verification (no effect unless env var set):
        // useful when the menu-bar icon is hidden behind the notch on a full bar.
        let env = ProcessInfo.processInfo.environment
        if env["HALLE_DEBUG_SHOW_SETTINGS"] == "1" {
            SettingsWindowController.shared.show()
        }
        if env["HALLE_DEBUG_SHOW_POPOVER"] == "1" {
            statusItemController?.showPopover()
        }
        if env["HALLE_DEBUG_SHOW_WORKSPACE"] == "1" {
            WorkspaceWindowController.shared.show()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = RecordingService.shared
        guard recorder.isRecording || recorder.state == .stopping else { return .terminateNow }
        recorder.finishBeforeTermination { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    /// Install a minimal main menu. An LSUIElement app has none by default, so the
    /// standard text-editing key equivalents (⌘X/⌘C/⌘V/⌘A, undo/redo) never reach
    /// text fields. The menu isn't shown for an accessory app, but NSApplication
    /// still uses it to route key equivalents to the focused field.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Hall-e", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    /// Re-opening the app (Finder/Spotlight/`open`) shows the agenda — a reliable
    /// way in even when the menu-bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItemController?.showPopover()
        return true
    }
}
