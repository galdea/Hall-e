import Foundation
import CoreML
import WhisperKit

/// Actor isolation keeps WhisperKit's Core ML pipeline (which is not Sendable)
/// on one executor while allowing the recording coordinator to remain async.
actor WhisperKitEngine {
    static let shared = WhisperKitEngine()

    private var pipeline: WhisperKit?
    private var loadedModel: String?

    func transcribe(fileURL: URL, sessionID: UUID, track: String,
                    model: String, language: String?) async throws -> Transcript {
        guard WhisperKitModelPaths.isDownloaded(model: model) else {
            throw TranscriptionError.modelNotDownloaded
        }
        let pipeline = try await loadPipeline(model: model)
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            wordTimestamps: false,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )
        let results = try await pipeline.transcribe(audioPath: fileURL.path, decodeOptions: options)
        let locale = language ?? results.first?.language ?? "auto"
        let segments = WhisperKitTranscriptionProvider.mapSegments(
            results, sessionID: sessionID, track: track
        )
        guard !segments.isEmpty else {
            throw TranscriptionError.failed("WhisperKit returned no speech segments.")
        }
        return Transcript(sessionID: sessionID, localeUsed: locale, segments: segments,
                          status: .completed,
                          source: WhisperKitTranscriptionProvider.source(for: model))
    }

    func unload() async {
        guard let pipeline else { return }
        await pipeline.unloadModels()
        self.pipeline = nil
        loadedModel = nil
    }

    private func loadPipeline(model: String) async throws -> WhisperKit {
        if let pipeline, loadedModel == model, pipeline.modelState == .loaded {
            return pipeline
        }
        await unload()
        guard let folder = WhisperKitModelPaths.downloadedFolder(for: model) else {
            throw TranscriptionError.modelNotDownloaded
        }
        let config = WhisperKitConfig(
            model: model,
            downloadBase: AppPaths.whisperKitModelsDir,
            modelRepo: WhisperKitModelPaths.repository,
            modelFolder: folder.path,
            tokenizerFolder: AppPaths.whisperKitModelsDir,
            // The default WhisperKit mel path uses GPU/ANE specialization.
            // On this Mac that path can abort inside Core ML before Swift can
            // catch an error. CPU-only keeps the durable job inside the app's
            // error boundary; it is slower but produces a recoverable result.
            computeOptions: ModelComputeOptions(melCompute: .cpuOnly,
                                                audioEncoderCompute: .cpuOnly,
                                                textDecoderCompute: .cpuOnly),
            prewarm: false,
            load: true,
            download: false
        )
        let newPipeline = try await WhisperKit(config)
        pipeline = newPipeline
        loadedModel = model
        return newPipeline
    }
}
