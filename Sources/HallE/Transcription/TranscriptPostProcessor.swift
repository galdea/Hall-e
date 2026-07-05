import Foundation

/// Optional LLM enrichment of a transcript → summary / decisions / action items,
/// merged into the meeting note. Strictly gated on the cloud-processing toggle.
struct TranscriptPostProcessor {
    let service: MeetingNoteService
    let notePath: String
    let context: MeetingContext

    /// Runs enrichment if AI + cloud transcript processing are enabled. Each step
    /// is independent — a failure in one never blocks the others or the transcript
    /// that's already safely merged.
    func enrich(transcript: String) async {
        let config = LLMProviderConfig.load()
        guard config.useAI, config.allowCloudTranscriptProcessing else {
            Log.ai.info("transcript enrichment skipped (cloud processing off)")
            return
        }
        let provider = LLMProviderFactory.make(config: config)
        if provider is DisabledLLMProvider { return }
        let pb = VaultPathBuilder(config: service.config)
        let writer = VaultWriter(vaultURL: service.vaultURL)

        if let summary = try? await provider.summarizeTranscript(transcript, context: context) {
            try? writer.mergeSection(relativePath: notePath, section: "summary", newContent: summary,
                                     headingAnchor: "Summary", mode: .replace, pathBuilder: pb)
        }
        if let actions = try? await provider.extractActionItems(transcript, context: context), !actions.isEmpty {
            let md = actions.map { item -> String in
                var line = "- [ ] \(item.task)"
                if let owner = item.owner, !owner.isEmpty { line += " (@\(owner))" }
                if let due = item.due_date, !due.isEmpty { line += " — due \(due)" }
                return line
            }.joined(separator: "\n")
            try? writer.mergeSection(relativePath: notePath, section: "actions", newContent: md,
                                     headingAnchor: "Action items", mode: .replace, pathBuilder: pb)
        }
    }
}
