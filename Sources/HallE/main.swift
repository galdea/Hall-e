import AppKit

// Manual bootstrap: Hall-e is an LSUIElement agent app living in the menu bar.
// No @main SwiftUI App — AppKit owns the lifecycle, SwiftUI renders the content.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
