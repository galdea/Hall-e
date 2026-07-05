import Foundation

enum AliasKind: String, Codable {
    case keyword, domain, email, personName, projectName

    var displayLabel: String {
        switch self {
        case .keyword: "Keyword"
        case .domain: "Domain"
        case .email: "Email"
        case .personName: "Person"
        case .projectName: "Project name"
        }
    }

    /// keyword/projectName are text signals subject to shared-keyword downweighting;
    /// email/domain/personName are inherently specific and exempt.
    var isTextSignal: Bool { self == .keyword || self == .projectName }
}
enum AliasStrength: String, Codable {
    case strong, normal, weak
    var multiplier: Double {
        switch self { case .strong: 1.0; case .normal: 1.0; case .weak: 0.6 }
    }
}

struct ProjectAlias: Codable, Hashable {
    var text: String
    var kind: AliasKind
    var strength: AliasStrength

    init(_ text: String, _ kind: AliasKind = .keyword, _ strength: AliasStrength = .normal) {
        self.text = text; self.kind = kind; self.strength = strength
    }
}

struct Project: Codable, Identifiable, Hashable {
    var id: String            // slug, e.g. "accurate", "vina-cousino-macul"
    var name: String          // display, e.g. "Viña Cousiño Macul"
    var aliases: [ProjectAlias]
    var isArchived: Bool = false

    /// Folder name for the Obsidian project note (display name is fine).
    var obsidianFolderName: String { name }
}

/// The fixed JSON contract for a classification result.
struct MeetingClassificationResult: Codable {
    var project: String?              // project display name, or nil
    var confidence: Double
    var reason: String
    var suggested_obsidian_path: String
    var requires_user_confirmation: Bool
    var source: String = "rules"      // "userRule" | "rules" | "llm" (not serialized in contract but useful)

    enum CodingKeys: String, CodingKey {
        case project, confidence, reason, suggested_obsidian_path, requires_user_confirmation
    }
}
