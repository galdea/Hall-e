import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Hall-e launching, bundle \(Bundle.main.bundleIdentifier ?? "nil", privacy: .public)")
        DebugFixtures.loadIfRequested()
        AppState.shared.startObserving()
        NotificationScheduler.shared.configure()
        if ObsidianVaultConfig.load() != nil {
            Features.current = ObsidianFeatureHooks()
        }
        statusItemController = StatusItemController()

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

        // Periodic + event-based syncing (timer, wake, network). Skipped under
        // fixtures so directly-inserted sample data isn't rebuilt away.
        if ProcessInfo.processInfo.environment["HALLE_DEBUG_FIXTURES"] != "1" {
            RefreshScheduler.shared.start()
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
        if env["HALLE_DEBUG_SHOW_AGENDA"] == "1" {
            AgendaWindowController.shared.show()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Re-opening the app (Finder/Spotlight/`open`) shows the agenda — a reliable
    /// way in even when the menu-bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItemController?.showPopover()
        return true
    }
}
