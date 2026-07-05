import AppKit
import SwiftUI

/// Retained window hosting the week/month agenda browser (same pattern as
/// SettingsWindowController). Reachable when the menu-bar icon is hidden.
@MainActor
final class AgendaWindowController: NSWindowController {
    static let shared = AgendaWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hall-e Agenda"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AgendaBrowserView())
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
