import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.text("onboarding.title"); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] completed in
            // "Skip for now" also counts as done — otherwise the window comes
            // back on every launch. The step is kept so Settings → rerun resumes.
            AppPreferences.onboardingCompleted = true
            if completed { AppPreferences.onboardingStep = 0 }
            self?.close()
            if completed { WorkspaceWindowController.shared.show() }
        })
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show() { NSApp.activate(ignoringOtherApps: true); window?.center(); window?.makeKeyAndOrderFront(nil) }
}
