import Foundation

/// Features whose execution depends on how Hall-e is distributed.
enum DistributionCapabilities {
    #if MAC_APP_STORE
    static let isMacAppStore = true
    #else
    static let isMacAppStore = false
    #endif

    static var usesSecurityScopedVaultAccess: Bool { isMacAppStore }
    static var supportsChromeNativeMessaging: Bool { !isMacAppStore }
    static var supportsCodexHomeImport: Bool { !isMacAppStore }
    static var supportsExternalArchiveProcess: Bool { !isMacAppStore }
    /// Process-tap capture has not passed sandboxed installed-package QA.
    static var supportsSystemAudioCapture: Bool { !isMacAppStore }
}
