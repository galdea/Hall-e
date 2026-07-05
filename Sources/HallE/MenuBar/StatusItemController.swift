import AppKit
import SwiftUI

/// Owns the NSStatusItem and the agenda popover.
/// Left click toggles the popover; right click shows a utility menu.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = Self.statusImage(recording: false)
            button.image = image
            if image == nil { button.title = "Hall-e" } // fallback if SF Symbol missing
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.isVisible = true

        popover.contentSize = NSSize(width: 440, height: 600)
        // Debug runs keep the popover pinned (and floated, below) so it can be
        // screenshotted without fighting other apps for focus.
        popover.behavior = ProcessInfo.processInfo.environment["HALLE_DEBUG_SHOW_POPOVER"] == "1"
            ? .applicationDefined : .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PopoverRootView())

        NotificationCenter.default.addObserver(forName: .halleRecordingChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setRecordingIndicator(RecordingService.shared.isRecording) }
        }
    }

    static func statusImage(recording: Bool) -> NSImage? {
        let name = recording ? "record.circle.fill" : "calendar.badge.clock"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hall-e")
        image?.isTemplate = !recording
        return image
    }

    func setRecordingIndicator(_ recording: Bool) {
        statusItem.button?.image = Self.statusImage(recording: recording)
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    // MARK: - Click handling

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        RefreshScheduler.shared.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Agent apps are never frontmost by default; activate so the popover gets key events.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        if ProcessInfo.processInfo.environment["HALLE_DEBUG_SHOW_POPOVER"] == "1" {
            popover.contentViewController?.view.window?.level = .floating
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        if RecordingService.shared.isRecording {
            let stop = menu.addItem(withTitle: "■ Stop recording", action: #selector(stopRecording), keyEquivalent: "")
            stop.target = self
            menu.addItem(.separator())
        } else {
            menu.addItem(withTitle: "Record WhatsApp call…", action: #selector(recordWhatsAppCall), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hall-e", action: #selector(quit), keyEquivalent: "q").target = self

        // Temporarily attach the menu so the status item shows it, then detach so
        // left click keeps toggling the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() {
        NotificationCenter.default.post(name: .halleManualRefresh, object: nil)
    }

    @objc private func stopRecording() {
        RecordingService.shared.stop()
    }

    @objc private func recordWhatsAppCall() {
        Features.current.startCallRecording()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let halleManualRefresh = Notification.Name("cl.gabriel.hall-e.manualRefresh")
}
