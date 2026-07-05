import Testing
import Foundation
@testable import HallE

@Suite("People → Project classification")
struct PeopleClassificationTests {
    private func makeEvent(title: String, attendeeEmails: [String] = [], desc: String? = nil) -> UnifiedEvent {
        let attendees = attendeeEmails.map { EventAttendee(name: nil, email: $0, responseStatus: nil, isSelf: false, isOrganizer: false) }
        let json = String(decoding: try! JSONEncoder().encode(attendees), as: UTF8.self)
        return UnifiedEvent(dedupKey: "k", title: title, startTs: Date(), endTs: Date(),
                            isAllDay: false, status: "confirmed", effectiveResponse: nil, meetingURL: nil,
                            location: nil, descriptionText: desc, htmlLink: nil, organizerEmail: nil,
                            attendeesJSON: json, iCalUID: nil, winnerAccountEmail: "a@x.com",
                            projectId: nil, projectConfidence: nil, sourcesJSON: "[]")
    }

    /// classificationProjects derives a tagged person's email → .email(strong) onto their project.
    @Test func personEmailClassifiesMeeting() {
        let projects = AliasStore.seed
        let accurateId = projects.first { $0.name == "Accurate" }!.id
        let person = Person(name: "Ana Ruiz", emails: ["ana@acmecorp.com"], projectIds: [accurateId])
        // Build a temporary AliasStore-equivalent by calling classificationProjects with explicit people
        // through a classifier constructed from the derived projects.
        let derived = deriveProjects(projects, people: [person])
        let r = MeetingClassifier(projects: derived, rules: UserRuleStore())
            .classify(makeEvent(title: "Weekly sync", attendeeEmails: ["ana@acmecorp.com"]))
        #expect(r.project == "Accurate")
        #expect(r.confidence >= 0.7)
    }

    @Test func transcriptClassifiesByKeywords() {
        let derived = deriveProjects(AliasStore.seed, people: [])
        let c = MeetingClassifier(projects: derived, rules: UserRuleStore())
        let hit = c.classifyTranscript(text: "Hablamos del director dashboard, los funcionarios del colegio y el sociograma para el clima escolar.")
        #expect(hit.project == "Accurate")
        let miss = c.classifyTranscript(text: "Just catching up about the weekend, nothing work related.")
        #expect(miss.project == nil)
    }

    @Test func personNameInTranscriptNudgesProject() {
        let projects = AliasStore.seed
        let rumboId = projects.first { $0.name == "Rumbo" }!.id
        let person = Person(name: "Zoraida Villalobos", projectIds: [rumboId])
        let derived = deriveProjects(projects, people: [person])
        let c = MeetingClassifier(projects: derived, rules: UserRuleStore())
        // Name alone is weak; pair with a rumbo keyword to cross the threshold.
        let r = c.classifyTranscript(text: "Llamada con Zoraida Villalobos sobre el flujo del agente de WhatsApp de Rumbo.")
        #expect(r.project == "Rumbo")
    }

    /// Mirror of AliasStore.classificationProjects but on an explicit project list (test helper).
    private func deriveProjects(_ base: [Project], people: [Person]) -> [Project] {
        var byId = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        for person in people where !person.isArchived {
            for pid in person.projectIds where byId[pid] != nil {
                person.emails.forEach { byId[pid]!.aliases.append(ProjectAlias($0, .email, .strong)) }
                if !person.name.isEmpty { byId[pid]!.aliases.append(ProjectAlias(person.name, .personName, .weak)) }
            }
        }
        return base.map { var p = byId[$0.id]!; p.aliases = Array(Set(p.aliases)); return p }
    }
}
