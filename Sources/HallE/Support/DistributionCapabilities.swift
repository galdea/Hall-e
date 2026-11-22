import Foundation

/// Features whose execution depends on how Hall-e is distributed.
enum DistributionCapabilities {
    #if MAC_APP_STORE
    static let isMacAppStore = true
    #else
    static let isMacAppStore = false
    #endif

    static var usesSecurityScopedVaultAccess: Bool { isMacAppStore }
    static var supportsChromeNativeMessaging: Bool { !isMacAppStore && !AppPaths.isStaging }
    /// Device pairing and shared meetings talk to the production pairing coordinator.
    /// Staging builds must never reach it, so the whole surface is unavailable there.
    static var supportsSharedMeetingCoordinator: Bool { supportsSharedMeetingCoordinator(isStaging: AppPaths.isStaging) }
    static func supportsSharedMeetingCoordinator(isStaging: Bool) -> Bool { !isStaging }
    static var sharedMeetingsUnavailableExplanation: String {
        PublicUICopy.text("Device pairing and shared meetings are turned off in this staging build because they use the production pairing service.",
                          "La vinculación de dispositivos y las reuniones compartidas están desactivadas en esta versión de staging porque usan el servicio de vinculación de producción.")
    }
    static var supportsCodexHomeImport: Bool { !isMacAppStore }
    static var supportsExternalArchiveProcess: Bool { !isMacAppStore }
    /// Process-tap capture has not passed sandboxed installed-package QA.
    static var supportsSystemAudioCapture: Bool { !isMacAppStore }
}
