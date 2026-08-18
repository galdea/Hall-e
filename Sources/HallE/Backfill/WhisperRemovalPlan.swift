import Foundation

struct WhisperRemovalPlan: Codable {
    var schemaVersion = "halle.whisper-removal-plan.v1"
    var createdAt: Date
    var requiresAcceptedReconciliation: Bool
    var requiresRollbackArtifact: Bool
    var appOwnedModelDirectory: String
    var sourcePaths: [String]
    var packageReferences: [String]
    var homebrewFormulae: [String]
    var preflightCommands: [String]
    var removalCommands: [String]
    var explicitlyForbiddenCommands: [String]
}

enum WhisperRemovalPlanner {
    /// Produces an auditable standalone plan only. Global package removal and
    /// app-owned model deletion remain separately confirmed operator actions.
    static func make(repository: URL) -> WhisperRemovalPlan {
        let sourcePaths = [
            "Sources/HallE/Transcription/WhisperCLITranscriptionProvider.swift",
            "Sources/HallE/Transcription/WhisperKitEngine.swift",
            "Sources/HallE/Transcription/WhisperKitModelManager.swift",
            "Sources/HallE/Transcription/WhisperKitTranscriptionProvider.swift",
        ]
        return .init(createdAt: Date(), requiresAcceptedReconciliation: true,
                     requiresRollbackArtifact: true,
                     appOwnedModelDirectory: AppPaths.whisperKitModelsDir.path,
                     sourcePaths: sourcePaths.map { repository.appendingPathComponent($0).path },
                     packageReferences: [repository.appendingPathComponent("Package.swift").path,
                                         repository.appendingPathComponent("Package.resolved").path],
                     homebrewFormulae: ["openai-whisper", "whisper-cpp"],
                     preflightCommands: ["brew info --json=v2 openai-whisper whisper-cpp",
                                         "brew uses --installed openai-whisper",
                                         "brew uses --installed whisper-cpp"],
                     removalCommands: ["brew uninstall openai-whisper", "brew uninstall whisper-cpp"],
                     explicitlyForbiddenCommands: ["brew autoremove"])
    }
}
