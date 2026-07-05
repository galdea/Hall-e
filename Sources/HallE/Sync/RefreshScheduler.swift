import Foundation
import AppKit
import Network

/// Drives periodic and event-based calendar syncs while keeping CPU/battery low:
/// a coarse timer, wake-from-sleep, and network-restored triggers. All syncs go
/// through `SyncCoordinator` which coalesces overlapping runs.
@MainActor
final class RefreshScheduler {
    static let shared = RefreshScheduler()

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var isOnline = true
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        scheduleTimer()

        // Initial sync shortly after launch (let DB observers settle first).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.kick(reason: "launch")
        }

        // Re-sync on wake (give the network a few seconds to come back).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.kick(reason: "wake")
            }
        }

        // Re-sync when connectivity is restored; gate syncs while offline.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let nowOnline = path.status == .satisfied
                let restored = nowOnline && !self.isOnline
                self.isOnline = nowOnline
                if restored { self.kick(reason: "network-restored") }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        // Re-arm the timer cadence if the preference changes.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleTimer() }
    }

    /// Refresh when the popover opens if the cache is stale (> 60s).
    func refreshIfStale() {
        guard !DebugFixtures.isActive else { return }
        if let last = AppState.shared.lastSyncAt, Date().timeIntervalSince(last) < 60 { return }
        kick(reason: "popover-open")
    }

    private func kick(reason: String) {
        guard isOnline else { Log.sync.info("skip sync (offline): \(reason, privacy: .public)"); return }
        Log.sync.info("sync trigger: \(reason, privacy: .public)")
        Task { await SyncCoordinator.shared.syncAll() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let minutes = max(1, AppPreferences.refreshIntervalMinutes)
        let interval = TimeInterval(minutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kick(reason: "timer") }
        }
        t.tolerance = interval * 0.2  // let the OS batch it → lower power use
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
