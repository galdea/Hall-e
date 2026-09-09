import Testing
import Foundation
@testable import HallE

@Suite("Project classifier (deterministic)")
struct ClassifierTests {
    private let projects = ClassificationFixtures.seed
    private func classify(_ input: ClassificationInput) -> MeetingClassificationResult {
        MeetingClassifier(projects: projects, rules: UserRuleStore()).classify(makeEvent(input))
    }
    private func makeEvent(_ input: ClassificationInput) -> UnifiedEvent {
        let attendees = zip(input.attendeeNames + Array(repeating: "", count: max(0, input.attendeeEmails.count - input.attendeeNames.count)),
                            input.attendeeEmails).map { EventAttendee(name: $0.0.isEmpty ? nil : $0.0, email: $0.1, responseStatus: nil, isSelf: false, isOrganizer: false) }
        let json = String(decoding: try! JSONEncoder().encode(attendees), as: UTF8.self)
        return UnifiedEvent(dedupKey: "k", title: input.title, startTs: Date(), endTs: Date(),
                            isAllDay: false, status: "confirmed", effectiveResponse: nil,
                            meetingURL: input.meetingURL, location: nil, descriptionText: input.description,
                            htmlLink: nil, organizerEmail: input.organizerEmail,
                            attendeesJSON: json, iCalUID: nil, winnerAccountEmail: "a@x.com",
                            projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
    }

    @Test func accurateDirectorDashboardAutoFilesHigh() {
        let r = classify(ClassificationInput(title: "Accurate — Director Dashboard Review",
                                             attendeeEmails: ["ana@getaccurate.cl"]))
        #expect(r.project == "Accurate")
        #expect(r.confidence >= 0.9)
        #expect(!r.requires_user_confirmation)
    }

    @Test func accurateFromTitleAloneStillStrong() {
        let r = classify(ClassificationInput(title: "Director Dashboard con funcionarios del colegio"))
        #expect(r.project == "Accurate")
        #expect(r.confidence >= 0.7)
    }

    @Test func almuerzoConSebastianGoesToInboxHonestly() {
        // Only a weak person-name signal → not confident → Inbox.
        let r = classify(ClassificationInput(title: "Almuerzo con Sebastián"))
        #expect(r.project == nil)
        #expect(r.requires_user_confirmation)
        #expect(r.confidence < 0.4)
        #expect(r.suggested_obsidian_path.contains("Inbox"))
    }

    @Test func diacriticInsensitiveMatching() {
        let accented = classify(ClassificationInput(title: "Viña Cousiño tour booking"))
        let plain = classify(ClassificationInput(title: "vina cousino tour booking"))
        #expect(accented.project == "Viña Cousiño Macul")
        #expect(plain.project == "Viña Cousiño Macul")
    }

    @Test func uniqueProductNameIsStrong() {
        #expect(classify(ClassificationInput(title: "Revisar Tourpay")).project == "Viña Cousiño Macul")
        #expect(classify(ClassificationInput(title: "Sociograma del clima escolar")).project == "Accurate")
        #expect(classify(ClassificationInput(title: "Config OpenPath lockbox")).project == "Oasis")
    }

    @Test func noKeywordsIsUnclassified() {
        let r = classify(ClassificationInput(title: "1:1 catch up"))
        #expect(r.project == nil)
        #expect(r.requires_user_confirmation)
    }

    @Test func userPinOverridesEverything() {
        var rules = UserRuleStore()
        rules.eventPins["k"] = "Matríztica"
        let event = makeEvent(ClassificationInput(title: "Accurate director dashboard"))  // would be Accurate
        let r = MeetingClassifier(projects: projects, rules: rules).classify(event)
        #expect(r.project == "Matríztica")
        #expect(r.confidence == 1.0)
        #expect(!r.requires_user_confirmation)
    }

    @Test func mundialeroFixture() {
        let r = classify(ClassificationInput(title: "El Mundialero — fixture y notificaciones partidos"))
        #expect(r.project == "El Mundialero")
        #expect(r.confidence >= 0.7)
    }

    @Test func exactEmailAliasClassifies() {
        var projects = ClassificationFixtures.seed
        let i = projects.firstIndex { $0.name == "Accurate" }!
        projects[i].aliases.append(ProjectAlias("ceo@acmecorp.com", .email, .strong))
        // A generic title, but the attendee email is pinned to Accurate.
        let event = makeEvent(ClassificationInput(title: "Weekly sync", attendeeEmails: ["ceo@acmecorp.com"]))
        let r = MeetingClassifier(projects: projects, rules: UserRuleStore()).classify(event)
        #expect(r.project == "Accurate")
        #expect(r.confidence >= 0.7)
    }

    @Test func sharedKeywordIsDownweightedToInbox() {
        var projects = ClassificationFixtures.seed
        // Same keyword added to two projects (the "Cloudflare in several projects" case).
        for name in ["Accurate", "Rumbo"] {
            let i = projects.firstIndex { $0.name == name }!
            projects[i].aliases.append(ProjectAlias("cloudflare", .keyword, .normal))
        }
        let event = makeEvent(ClassificationInput(title: "Discuss cloudflare setup"))
        let scores = RulesEngine.score(ClassificationInput(from: event), projects: projects)
        // 0.55 (alias in title) / 2 shared = 0.275, below the 0.40 inbox threshold.
        #expect((scores.first?.value ?? 1) < 0.40)
        let r = MeetingClassifier(projects: projects, rules: UserRuleStore()).classify(event)
        #expect(r.project == nil)  // not confidently any single project
    }

    @Test func uniqueKeywordStillWinsOverSharedOne() {
        var projects = ClassificationFixtures.seed
        for name in ["Accurate", "Rumbo", "Oasis"] {
            let i = projects.firstIndex { $0.name == name }!
            projects[i].aliases.append(ProjectAlias("workshop", .keyword, .normal))
        }
        // "sociograma" is unique+strong to Accurate; "workshop" is shared 3 ways.
        let r = classifyWith(projects, ClassificationInput(title: "Sociograma workshop"))
        #expect(r.project == "Accurate")
    }

    private func classifyWith(_ projects: [Project], _ input: ClassificationInput) -> MeetingClassificationResult {
        MeetingClassifier(projects: projects, rules: UserRuleStore()).classify(makeEvent(input))
    }
}
