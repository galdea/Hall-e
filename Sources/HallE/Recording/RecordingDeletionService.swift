import Foundation

@MainActor
enum RecordingDeletionService {
    enum DeletionError: LocalizedError {
        case activeRecording

        var errorDescription: String? {
            "Stop the active recording before deleting it."
        }
    }

    static func delete(_ session: RecordingSession) throws {
        guard RecordingService.shared.currentSession?.id != session.id else {
            throw DeletionError.activeRecording
        }
        if RecordingPlaybackService.shared.activeSessionID == session.id {
            RecordingPlaybackService.shared.stop()
        }
        try RecordingStore.delete(session)
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
