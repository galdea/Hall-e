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

        guard let insights = try? await provider.extractMeetingInsights(transcript, context: context) else {
            Log.ai.error("structured meeting insights failed")
            return
        }
        merge(writer, section: "summary",
              content: nonEmpty(insights.summary, fallback: "_(No se generó un resumen.)_"),
              anchor: "Summary", pathBuilder: pb)

        let decisions = insights.decisions.isEmpty
            ? "_(No se registraron decisiones.)_"
            : insights.decisions.map { "- \($0)" }.joined(separator: "\n")
        merge(writer, section: "decisions", content: decisions,
              anchor: "Decisions", pathBuilder: pb)

        let actions: String
        if insights.actionItems.isEmpty {
            actions = "_(No se registraron acciones.)_"
        } else {
            actions = insights.actionItems.map { item -> String in
                var line = "- [ ] \(item.task)"
                if let owner = item.owner, !owner.isEmpty { line += " (@\(owner))" }
                if let due = item.due_date, !due.isEmpty { line += " — due \(due)" }
                return line
            }.joined(separator: "\n")
        }
        merge(writer, section: "actions", content: actions,
              anchor: "Action items", pathBuilder: pb)

        let followUps = insights.followUps.isEmpty
            ? "_(No se registraron seguimientos.)_"
            : insights.followUps.map { "- \($0)" }.joined(separator: "\n")
        merge(writer, section: "followups", content: followUps,
              anchor: "Follow-ups", pathBuilder: pb)
    }

    /// Enrichment sections are best-effort, but a failed merge must show up in
    /// the log — the user otherwise sees a "completed" note missing sections.
    private func merge(_ writer: VaultWriter, section: String, content: String,
                       anchor: String, pathBuilder: VaultPathBuilder) {
        do {
            try writer.mergeSection(relativePath: notePath, section: section, newContent: content,
                                    headingAnchor: anchor, mode: .replace, pathBuilder: pathBuilder)
        } catch {
            Log.ai.error("merging \(section, privacy: .public) into note failed: \(error, privacy: .public)")
        }
    }

    private func nonEmpty(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }
}
