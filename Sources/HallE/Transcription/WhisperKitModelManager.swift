import Foundation
import Observation
import WhisperKit

enum WhisperKitModelPaths {
    static let repository = "argmaxinc/whisperkit-coreml"

    static func folder(for model: String, downloadBase: URL = AppPaths.whisperKitModelsDir) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
    }

    static func downloadedFolder(for model: String, downloadBase: URL = AppPaths.whisperKitModelsDir) -> URL? {
        let direct = folder(for: model, downloadBase: downloadBase)
        if containsModelFiles(direct) { return direct }

        guard let enumerator = FileManager.default.enumerator(
            at: downloadBase,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let candidate as URL in enumerator where candidate.lastPathComponent == model {
            if containsModelFiles(candidate) { return candidate }
        }
        return nil
    }

    static func isDownloaded(model: String, downloadBase: URL = AppPaths.whisperKitModelsDir) -> Bool {
        downloadedFolder(for: model, downloadBase: downloadBase) != nil
    }

    private static func containsModelFiles(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
    }
}

@MainActor
@Observable
final class WhisperKitModelManager {
    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case preparing
        case ready
        case failed(String)
    }

    static let shared = WhisperKitModelManager()

    private(set) var state: State

    var isModelDownloaded: Bool {
        WhisperKitModelPaths.isDownloaded(model: AppPreferences.whisperKitModel)
    }

    var modelFolder: URL? {
        WhisperKitModelPaths.downloadedFolder(for: AppPreferences.whisperKitModel)
    }

    private init() {
        state = WhisperKitModelPaths.isDownloaded(model: AppPreferences.whisperKitModel) ? .ready : .notDownloaded
    }

    func refresh() {
        state = isModelDownloaded ? .ready : .notDownloaded
    }

    /// Prepare the configured primary engine for the next recording. This is
    /// intentionally called from Hall-e's launch recovery task, so a meeting
    /// never starts with a missing model and silently falls through to Apple
    /// Speech. The UI still exposes the progress and failure state in Settings.
    func prepareIfNeeded() async {
        guard AppPreferences.transcriptionEngine != .sfSpeech,
              !WhisperCLITranscriptionProvider.isAvailable,
              !isModelDownloaded else { return }
        await downloadAndPrepare()
    }

    func downloadAndPrepare() async {
        guard !isDownloading else { return }
        let model = AppPreferences.whisperKitModel
        let base = AppPaths.whisperKitModelsDir
        state = .downloading(progress: 0)

        do {
            let folder = try await WhisperKit.download(
                variant: model,
                downloadBase: base,
                from: WhisperKitModelPaths.repository,
                progressCallback: { [weak self] progress in
                    let fraction = min(1, max(0, progress.fractionCompleted))
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(progress: fraction)
                    }
                }
            )
            state = .preparing

            // Do not load/compile Core ML here. On some macOS/Apple-silicon
            // combinations that eager specialization aborts the host process
            // instead of throwing. WhisperKitEngine loads lazily with its
            // recoverable CPU-only compute configuration when a job runs.
            _ = folder
            state = .ready
        } catch {
            state = .failed(TranscriptionErrorSanitizer.message(error))
        }
    }

    func removeModel() {
        let model = AppPreferences.whisperKitModel
        guard let folder = WhisperKitModelPaths.downloadedFolder(for: model) else {
            state = .notDownloaded
            return
        }
        do {
            try FileManager.default.removeItem(at: folder)
            state = .notDownloaded
        } catch {
            state = .failed("Could not remove the local WhisperKit model: \(error.localizedDescription)")
        }
    }

    private var isDownloading: Bool {
        switch state {
        case .downloading, .preparing: true
        default: false
        }
    }
}
