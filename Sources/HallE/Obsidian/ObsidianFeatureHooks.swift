import Foundation
import AppKit

/// Implements the agenda/notification feature seams using the Obsidian layer.
@MainActor
final class ObsidianFeatureHooks: FeatureHooks {
    var canOpenObsidian: Bool { ObsidianVaultConfig.load() != nil && VaultAccess.isReachable() }

    func prepareNote(for event: UnifiedEvent) {
        makeNote(for: event, open: true)
    }

    func openInObsidian(_ event: UnifiedEvent) {
        makeNote(for: event, open: true)
    }

    func startRecording(for event: UnifiedEvent) {
        RecordingCoordinator.startRecording(for: event)
    }

    func startCallRecording() {
        RecordingCoordinator.startCallRecording()
    }

    private func makeNote(for event: UnifiedEvent, open: Bool) {
        guard VaultAccess.isReachable() else {
            notifyVaultUnreachable(); return
        }
        guard let service = MeetingNoteService.make() else { return }
        Task.detached {
            do {
                let descriptor = try service.createOrFindMeetingNote(for: event, projectName: event.projectId)
                if open {
                    await MainActor.run {
                        ObsidianURIOpener.open(vaultRelativePath: descriptor.vaultRelativePath)
                    }
                }
                Log.obsidian.info("meeting note ready (created=\(descriptor.wasCreated, privacy: .public))")
            } catch {
                Log.obsidian.error("note creation failed: \(error, privacy: .public)")
                await MainActor.run { self.notifyError(error) }
            }
        }
    }

    private func notifyVaultUnreachable() {
        let alert = NSAlert()
        alert.messageText = "Obsidian vault not available"
        alert.informativeText = "Choose your vault in Settings → Obsidian, and make sure the folder exists."
        alert.runModal()
    }

    private func notifyError(_ error: Error) {
        Log.obsidian.error("obsidian error surfaced: \(error.localizedDescription, privacy: .public)")
    }
}
