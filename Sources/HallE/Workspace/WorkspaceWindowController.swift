import AppKit
import SwiftUI

@MainActor
final class WorkspaceWindowController {
    static let shared = WorkspaceWindowController()
    private var window: NSWindow?
    private let model = WorkspaceViewModel()

    func showMeeting(dedupKey: String) {
        model.openMeeting(dedupKey: dedupKey)
        show()
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let controller = NSHostingController(rootView: WorkspaceRootView(model: model))
        let window = NSWindow(contentViewController: controller)
        window.title = "Hall-e"
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 900, height: 600)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setFrameAutosaveName("Hall-e Workspace")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
