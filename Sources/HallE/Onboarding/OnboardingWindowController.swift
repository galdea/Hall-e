import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 690),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("onboarding.title"); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.minSize = NSSize(width: 660, height: 600)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show() {
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        window?.contentView = NSHostingView(rootView: OnboardingView { [weak self] completed in
            if completed {
                AppPreferences.onboardingCompleted = true
                AppPreferences.onboardingStep = 0
            }
            self?.close()
            WorkspaceWindowController.shared.show()
        })
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        WorkspaceWindowController.shared.show()
    }
}
