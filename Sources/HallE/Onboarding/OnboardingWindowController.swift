import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("onboarding.title"); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show() {
        window?.contentView = NSHostingView(rootView: OnboardingView { [weak self] _ in
            AppPreferences.onboardingCompleted = true
            AppPreferences.onboardingStep = 0
            self?.close()
            WorkspaceWindowController.shared.show()
        })
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
