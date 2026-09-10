import Foundation

@MainActor
enum RecordingDeletionService {
    enum DeletionError: LocalizedError {
        case activeRecording
        case activeProcessing

        var errorDescription: String? {
            switch self {
            case .activeRecording: "Stop the active recording before deleting it."
            case .activeProcessing: "Wait for this recording to finish processing before deleting it."
            }
        }
    }

    static func delete(_ session: RecordingSession) throws {
        guard RecordingService.shared.currentSession?.id != session.id else {
            throw DeletionError.activeRecording
        }
        guard !RecordingCoordinator.isProcessing(sessionID: session.id) else {
            throw DeletionError.activeProcessing
        }
        if RecordingPlaybackService.shared.activeSessionID == session.id {
            RecordingPlaybackService.shared.stop()
        }
        try RecordingStore.delete(session)
        RecordingCoordinator.cancelScheduledRetry(sessionID: session.id)
        clearRecordingPath(in: session.notePath)
        NotificationCenter.default.post(name: .halleRecordingChanged, object: nil)
    }

    private static func clearRecordingPath(in notePath: String?) {
        guard let notePath,
              let config = ObsidianVaultConfig.load(),
              let vaultURL = VaultAccess.currentVaultURL() else { return }
        do {
            try VaultWriter(vaultURL: vaultURL).updateFrontmatter(
                relativePath: notePath,
                key: "recording_path",
                value: "",
                pathBuilder: VaultPathBuilder(config: config))
        } catch {
            Log.rec.warning("recording deleted but note link could not be cleared: \(error, privacy: .public)")
        }
    }
}
