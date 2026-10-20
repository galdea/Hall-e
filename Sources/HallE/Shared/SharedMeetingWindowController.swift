import AppKit
import SwiftUI

/// Presents a validated pairing invitation for review. Opening a custom URL
/// never joins automatically; the user must still choose Connect in the view
/// and confirm the sharing disclosure.
@MainActor
final class SharedMeetingWindowController: NSWindowController {
    static let shared = SharedMeetingWindowController()

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(invitation: String) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Devices & shared meetings"
            window.minSize = NSSize(width: 700, height: 600)
            window.contentView = NSHostingView(rootView: SharedMeetingsView(pendingInvitation: invitation))
            window.center()
            self.window = window
        } else {
            window?.contentView = NSHostingView(rootView: SharedMeetingsView(pendingInvitation: invitation))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
