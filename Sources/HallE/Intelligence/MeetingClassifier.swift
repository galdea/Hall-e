import Foundation

/// User pins that override automatic classification.
/// Keyed by unified-event dedupKey and by recurring-series iCalUID.
struct UserRuleStore: Codable {
    var eventPins: [String: String] = [:]   // dedupKey → projectName
    var seriesPins: [String: String] = [:]  // iCalUID → projectName

    static func load() -> UserRuleStore {
        (try? JSONDecoder().decode(UserRuleStore.self, from: Data(contentsOf: AppPaths.userRulesFile)))
            ?? UserRuleStore()
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: AppPaths.userRulesFile, options: [.atomic])
        }
    }
}

/// Orchestrates classification: user pins → deterministic rules → (optional LLM,
/// wired in a later phase). Never invents confidence.
struct MeetingClassifier {
    var projects: [Project]
    var rules: UserRuleStore

    init(projects: [Project] = AliasStore.shared.projects, rules: UserRuleStore = .load()) {
        self.projects = projects
        self.rules = rules
    }

    func classify(_ event: UnifiedEvent) -> MeetingClassificationResult {
        // 1. User pins win outright.
        if let pinned = rules.eventPins[event.dedupKey] ?? event.iCalUID.flatMap({ rules.seriesPins[$0] }) {
            return MeetingClassificationResult(
                project: pinned, confidence: 1.0, reason: "user rule",
                suggested_obsidian_path: path(for: pinned),
                requires_user_confirmation: false, source: "userRule")
        }

        // 2. Deterministic rules.
        let scores = RulesEngine.score(ClassificationInput(from: event), projects: projects)
        let top = scores.first
        let s1 = top?.value ?? 0
        let s2 = scores.dropFirst().first?.value ?? 0

        guard let top, s1 >= RulesEngine.inboxThreshold else {
            return MeetingClassificationResult(
                project: nil, confidence: max(0, s1),
                reason: top.map { "weak/no evidence (best: \($0.project.name) \(pct(s1)))" } ?? "no matching keywords",
                suggested_obsidian_path: inboxPath(), requires_user_confirmation: true, source: "rules")
        }

        let ambiguous = (s1 - s2) < RulesEngine.ambiguityGap && s2 > 0
        if ambiguous {
            return MeetingClassificationResult(
                project: top.project.name, confidence: min(s1, 0.6),
                reason: "ambiguous: \(top.project.name) vs \(scores[1].project.name)",
                suggested_obsidian_path: inboxPath(), requires_user_confirmation: true, source: "rules")
        }

        if s1 >= RulesEngine.autoFileThreshold {
            return MeetingClassificationResult(
                project: top.project.name, confidence: s1,
                reason: top.reasons.prefix(3).joined(separator: "; "),
                suggested_obsidian_path: path(for: top.project.name),
                requires_user_confirmation: false, source: "rules")
        }

        // 0.4 ≤ s1 < 0.7 → suggest, but ask.
        return MeetingClassificationResult(
            project: top.project.name, confidence: s1,
            reason: top.reasons.prefix(3).joined(separator: "; "),
            suggested_obsidian_path: inboxPath(), requires_user_confirmation: true, source: "rules")
    }

    /// Whether the deterministic verdict is confident enough to skip the LLM.
    func isConfident(_ result: MeetingClassificationResult) -> Bool {
        result.source == "userRule" || (!result.requires_user_confirmation && result.project != nil)
    }

    /// Optional LLM fallback. Only trust a returned project that is one of our
    /// known names; clamp confidence; never invent. Returns nil on any failure.
    func aiClassify(_ event: UnifiedEvent, provider: LLMProvider) async -> MeetingClassificationResult? {
        let names = projects.map(\.name)
        guard let raw = try? await provider.classifyMeeting(ClassificationInput(from: event), candidates: names) else {
            return nil
        }
        let project: String? = raw.project.flatMap { names.contains($0) ? $0 : nil }
        let confidence = min(max(raw.confidence, 0), 1)
        let confident = project != nil && confidence >= RulesEngine.autoFileThreshold
        return MeetingClassificationResult(
            project: confident ? project : nil,
            confidence: confidence,
            reason: "llm: \(raw.reason)",
            suggested_obsidian_path: confident ? path(for: project!) : inboxPath(),
            requires_user_confirmation: !confident,
            source: "llm")
    }

    private func path(for projectName: String) -> String { "Projects/\(projectName)" }
    private func inboxPath() -> String { "Inbox" }
    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
}
