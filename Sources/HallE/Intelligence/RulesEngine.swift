import Foundation

/// The signals a classifier reads from an event.
struct ClassificationInput {
    var title: String
    var description: String?
    var attendeeEmails: [String]
    var attendeeNames: [String]
    var organizerEmail: String?
    var meetingURL: String?

    init(from event: UnifiedEvent) {
        title = event.title
        description = event.descriptionText
        let attendees = event.attendees
        attendeeEmails = attendees.compactMap { $0.email }
        attendeeNames = attendees.compactMap { $0.name }
        organizerEmail = event.organizerEmail
        meetingURL = event.meetingURL
    }

    init(title: String, description: String? = nil, attendeeEmails: [String] = [],
         attendeeNames: [String] = [], organizerEmail: String? = nil, meetingURL: String? = nil) {
        self.title = title; self.description = description
        self.attendeeEmails = attendeeEmails; self.attendeeNames = attendeeNames
        self.organizerEmail = organizerEmail; self.meetingURL = meetingURL
    }
}

/// Deterministic, layered keyword scorer. Per project, matched signals combine
/// via noisy-OR (score = 1 − Π(1 − wᵢ)); highest score wins subject to threshold
/// and tie-break policy.
enum RulesEngine {
    // Base weights per signal (before alias-strength multiplier).
    private enum W {
        static let projectNameInTitle = 0.80
        static let attendeeEmailExact = 0.70   // a specific address is strong, precise evidence
        static let aliasInTitle = 0.55
        static let attendeeDomain = 0.50
        static let attendeeNameOrLocal = 0.35
        static let inDescription = 0.30
        static let organizer = 0.30
        static let inMeetingURL = 0.20
    }

    static let autoFileThreshold = 0.70
    static let inboxThreshold = 0.40
    static let ambiguityGap = 0.15

    struct Score {
        var project: Project
        var value: Double
        var reasons: [String]
    }

    /// Score every project against the input.
    static func score(_ input: ClassificationInput, projects: [Project]) -> [Score] {
        // Inverse-project-frequency: how many projects use each text keyword.
        // A keyword shared by K projects is K× less discriminative, so its
        // contribution is scaled by 1/K. email/domain/person aliases are exempt.
        var sharedCount: [String: Int] = [:]
        for project in projects {
            var seen = Set<String>()
            for alias in project.aliases where alias.kind.isTextSignal {
                let key = TextNormalizer.fold(alias.text)
                if seen.insert(key).inserted { sharedCount[key, default: 0] += 1 }
            }
        }

        let emails = input.attendeeEmails.map { TextNormalizer.fold($0) }
            + (input.organizerEmail.map { [TextNormalizer.fold($0)] } ?? [])

        return projects.map { project in
            var contributions: [Double] = []
            var reasons: [String] = []
            let domains = input.attendeeEmails.compactMap { TextNormalizer.domain(ofEmail: $0) }
            let locals = input.attendeeEmails.map { $0.split(separator: "@").first.map(String.init) ?? $0 }

            for alias in project.aliases {
                var best = 0.0
                var why = ""

                switch alias.kind {
                case .email:
                    if emails.contains(TextNormalizer.fold(alias.text)) {
                        best = W.attendeeEmailExact; why = "attendee email \(alias.text)"
                    }
                case .domain:
                    if domains.contains(where: { $0 == TextNormalizer.fold(alias.text) || $0.hasSuffix(TextNormalizer.fold(alias.text)) }) {
                        best = W.attendeeDomain; why = "attendee domain \(alias.text)"
                    }
                default:
                    if TextNormalizer.containsPhrase(input.title, alias.text) {
                        let w = alias.kind == .projectName ? W.projectNameInTitle : W.aliasInTitle
                        if w > best { best = w; why = "title: \(alias.text)" }
                    }
                    if let desc = input.description, TextNormalizer.containsPhrase(desc, alias.text), W.inDescription > best {
                        best = W.inDescription; why = "description: \(alias.text)"
                    }
                    if input.attendeeNames.contains(where: { TextNormalizer.containsPhrase($0, alias.text) })
                        || locals.contains(where: { TextNormalizer.containsPhrase($0, alias.text) }), W.attendeeNameOrLocal > best {
                        best = W.attendeeNameOrLocal; why = "attendee: \(alias.text)"
                    }
                    if let org = input.organizerEmail, TextNormalizer.containsPhrase(org, alias.text), W.organizer > best {
                        best = W.organizer; why = "organizer: \(alias.text)"
                    }
                    if let url = input.meetingURL, TextNormalizer.containsPhrase(url, alias.text), W.inMeetingURL > best {
                        best = W.inMeetingURL; why = "link: \(alias.text)"
                    }
                }

                guard best > 0 else { continue }
                var weight = best * alias.strength.multiplier
                var note = why + (alias.strength == .weak ? " (weak)" : "")

                // Downweight keywords shared across multiple projects.
                if alias.kind.isTextSignal {
                    let shared = sharedCount[TextNormalizer.fold(alias.text)] ?? 1
                    if shared > 1 {
                        weight /= Double(shared)
                        note += " (shared×\(shared))"
                    }
                }
                contributions.append(weight)
                reasons.append(note)
            }

            let combined = 1.0 - contributions.reduce(1.0) { $0 * (1.0 - $1) }
            return Score(project: project, value: combined, reasons: reasons)
        }
        .sorted { $0.value > $1.value }
    }
}
