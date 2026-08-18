import Testing
import Foundation
@testable import HallE

@Suite("Recording library layout and naming")
struct RecordingLibraryTests {
    private let start = Date(timeIntervalSince1970: 1_785_880_800)   // 2026-08-04 local

    // MARK: - Naming

    @Test func nameCarriesTheSubjectAndThePeopleWhoTookPart() {
        let name = RecordingFolderName.compose(startedAt: start,
                                               topic: "Revisión de resultados y plan de lanzamiento",
                                               fallbackTitle: "Get Accurate",
                                               participants: ["Sebastián", "Álvaro"])
        #expect(name.contains("Revisión de resultados y plan de lanzamiento"))
        #expect(name.hasSuffix("Sebastián, Álvaro"))
        #expect(!name.contains("Get Accurate"))
        // Leads with a sortable stamp so a project folder reads chronologically.
        #expect(name.hasPrefix(HalleDate.day(start)))
    }

    /// Without AI — or when the model declines — the calendar title stands in.
    /// A recording must never end up with an invented name.
    @Test func nameFallsBackToTheCalendarTitleWithoutATopic() {
        let name = RecordingFolderName.compose(startedAt: start, topic: nil,
                                               fallbackTitle: "Kickoff IMBA Tamango",
                                               participants: ["Ana"])
        #expect(name.contains("Kickoff IMBA Tamango"))
        #expect(name.hasSuffix("Ana"))
    }

    @Test func nameOmitsParticipantsWhenNobodyElseAttended() {
        let name = RecordingFolderName.compose(startedAt: start, topic: "Notas personales",
                                               fallbackTitle: "Solo", participants: [])
        #expect(name.hasSuffix("Notas personales"))
    }

    @Test func largeMeetingsAreSummarisedRatherThanListedInFull() {
        let segment = RecordingFolderName.participantSegment(["Ana", "Bruno", "Carla", "Diego", "Eva", "Fran"])
        #expect(segment == "Ana, Bruno, Carla, Diego +2")
    }

    @Test func participantsAreDeduplicatedCaseInsensitively() {
        #expect(RecordingFolderName.participantSegment(["Ana", "ana", "Bruno"]) == "Ana, Bruno")
    }

    @Test func topicIsStrippedOfModelDecoration() {
        #expect(RecordingFolderName.cleanTopic("\"Plan de lanzamiento\".") == "Plan de lanzamiento")
        #expect(RecordingFolderName.cleanTopic("- Revisión de métricas") == "Revisión de métricas")
        #expect(RecordingFolderName.cleanTopic("Primera línea\nsegunda línea") == "Primera línea")
        #expect(RecordingFolderName.cleanTopic("   ") == nil)
        #expect(RecordingFolderName.cleanTopic(nil) == nil)
    }

    @Test func participantNamesPreferCalendarThenDirectoryThenEmail() {
        let directory = [Person(name: "Álvaro Carrasco", emails: ["alvaro.carrasco@braveup.cl"])]
        #expect(RecordingFolderName.displayName(forEmail: "x@y.cl", calendarName: "Sebastián Ruiz",
                                                directory: directory) == "Sebastián")
        #expect(RecordingFolderName.displayName(forEmail: "ALVARO.CARRASCO@braveup.cl", calendarName: nil,
                                                directory: directory) == "Álvaro")
        #expect(RecordingFolderName.displayName(forEmail: "maria.jose@imba.cl", calendarName: nil,
                                                directory: []) == "Maria")
        #expect(RecordingFolderName.displayName(forEmail: nil, calendarName: nil, directory: []) == nil)
        // Role/initials mailboxes are not people; naming a folder after "Ac" is
        // worse than leaving the attendee out.
        #expect(RecordingFolderName.displayName(forEmail: "ac@imba.cl", calendarName: nil,
                                                directory: []) == nil)
        #expect(RecordingFolderName.displayName(forEmail: "rcarrillo@imba.cl", calendarName: nil,
                                                directory: []) == "Rcarrillo")
    }

    @Test func nameStaysWithinTheFilesystemBudget() {
        let name = RecordingFolderName.compose(startedAt: start,
                                               topic: String(repeating: "muy largo ", count: 60),
                                               fallbackTitle: "x",
                                               participants: ["Ana", "Bruno", "Carla", "Diego"])
        #expect(name.utf8.count <= RecordingFolderName.maximumNameBytes)
    }

    @Test func unclassifiedMeetingsGetTheirOwnThematicFolder() {
        #expect(RecordingFolderName.projectFolder("Accurate") == "Accurate")
        #expect(RecordingFolderName.projectFolder(nil) == RecordingFolderName.unclassifiedProject)
        #expect(RecordingFolderName.projectFolder("  ") == RecordingFolderName.unclassifiedProject)
        #expect(RecordingFolderName.projectFolder("IMBA/Tamango") == "IMBA Tamango")
    }

    /// Two meetings can share a subject and a minute. Renaming onto an existing
    /// folder would overwrite a recording, so the newcomer's name gives way.
    @Test func collidingNamesNeverOverwriteAnExistingRecording() {
        let taken: Set<String> = ["2026-08-04 1000 - Weekly - Ana",
                                  "2026-08-04 1000 - Weekly - Ana (2)"]
        let name = RecordingLibrary.uniqueName("2026-08-04 1000 - Weekly - Ana") { taken.contains($0) }
        #expect(name == "2026-08-04 1000 - Weekly - Ana (3)")
        #expect(!taken.contains(name))
    }

    @Test func uniqueNameLeavesAFreeNameAlone() {
        #expect(RecordingLibrary.uniqueName("free") { _ in false } == "free")
    }

    // MARK: - Project resolution

    private static let knownProjects = ["Accurate", "El Mundialero", "Tamango", "Matríztica",
                                        "Viña Cousiño Macul"]

    /// Most of an existing library predates event snapshots. The meeting note's
    /// path is the filing the user already sees, so it decides those.
    @Test func projectComesFromTheMeetingNoteWhenTheSnapshotIsMissing() {
        let cases = [
            ("Hall-e/Meetings/2026/2026-07/2026-07-06 - Accurate - Get Accurate.md", "Accurate"),
            ("Hall-e/Meetings/2026/2026-07/2026-07-15 - Accurate - Accurate - Reunión Directorio - 31ff1198.md", "Accurate"),
            ("Hall-e/Meetings/2026/2026-07/2026-07-10 - El Mundialero - El Mundialero Winner Match 93 - 613ac067.md", "El Mundialero"),
            ("Hall-e/Meetings/2026/2026-07/2026-07-14 - Tamango - Kickoff IMBA Tamango - 40336e30.md", "Tamango"),
        ]
        for (path, expected) in cases {
            #expect(RecordingProjectResolver.projectFromNotePath(path, knownProjects: Self.knownProjects) == expected)
        }
    }

    /// An inbox note's second field is its title, not a project — filing on
    /// position alone would invent a project called "Pre-Revisión Resultados".
    @Test func inboxNotesStayUnclassified() {
        let inbox = "Hall-e/Inbox/2026-07-22 - Pre-Revisión Resultados - 376bccb1.md"
        #expect(RecordingProjectResolver.projectFromNotePath(inbox, knownProjects: Self.knownProjects) == nil)
        let call = "Hall-e/Calls/Inbox/2026-07-21 - WhatsApp call - a84ea3bb.md"
        #expect(RecordingProjectResolver.projectFromNotePath(call, knownProjects: Self.knownProjects) == nil)
    }

    @Test func unknownProjectNamesInANotePathAreRejected() {
        let path = "Hall-e/Meetings/2026/2026-07/2026-07-06 - Something Else - Title - abc.md"
        #expect(RecordingProjectResolver.projectFromNotePath(path, knownProjects: Self.knownProjects) == nil)
    }

    @Test func resolutionPrefersTheLiveClassificationThenTheSnapshot() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        var session = root.makeSession(title: "Get Accurate", project: "Accurate")
        session.notePath = "Hall-e/Meetings/2026/2026-07/2026-07-06 - Tamango - Get Accurate.md"

        #expect(RecordingProjectResolver.project(for: session, explicit: "El Mundialero",
                                                 knownProjects: Self.knownProjects) == "El Mundialero")
        #expect(RecordingProjectResolver.project(for: session, knownProjects: Self.knownProjects) == "Accurate")
    }

    /// Re-titling an already-filed recording must not drop it into Unclassified
    /// just because its snapshot and note have nothing to say.
    @Test func alreadyFiledRecordingsKeepTheirProject() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        var session = root.makeSession(title: "Weekly", project: nil)
        session.notePath = nil
        session.folderPath = "Tamango/2026-08-04 1801 - Weekly - Ana"

        #expect(RecordingProjectResolver.project(for: session, knownProjects: Self.knownProjects) == "Tamango")
    }

    @Test func aRecordingWithNoSignalAtAllIsUnclassified() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        var session = root.makeSession(title: "Llamada de WhatsApp", project: nil)
        session.notePath = nil
        session.folderPath = nil
        #expect(RecordingProjectResolver.project(for: session, knownProjects: Self.knownProjects) == nil)
    }

    // MARK: - Layout

    @Test func storeReadsRecordingsFromProjectFoldersAndTheLegacyFlatLayout() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        try root.write(session: root.makeSession(title: "Filed", project: "Accurate"),
                       at: "Accurate/2026-08-04 1801 - Filed - Ana")
        try root.write(session: root.makeSession(title: "Also filed", project: "Tamango"),
                       at: "Tamango/2026-08-04 0900 - Also filed - Bruno")
        var legacy = root.makeSession(title: "Not yet migrated", project: nil)
        legacy.folderPath = nil
        try root.write(session: legacy, at: "2026-07-24-1301-legacy-slug")

        let titles = Set(RecordingStore.sessions(in: root.url).map(\.eventTitle))
        #expect(titles == ["Filed", "Also filed", "Not yet migrated"])
    }

    @Test func storeIgnoresStrayFoldersWithoutASession() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("Accurate/empty"),
                                                withIntermediateDirectories: true)
        #expect(RecordingStore.sessions(in: root.url).isEmpty)
    }

    // MARK: - Deletion guards

    @Test func deletesOneNestedRecordingFolder() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        let relative = "Accurate/2026-08-04 1801 - Filed - Ana"
        try root.write(session: root.makeSession(title: "Filed", project: "Accurate"), at: relative)

        try RecordingStore.deleteSessionFolder(relativePath: relative, recordingsDirectory: root.url)

        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent(relative).path))
        // The thematic folder survives its last recording being deleted.
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Accurate").path))
    }

    /// A project folder holds every recording for a theme. Deleting one because
    /// a relative path was wrong would be an unrecoverable loss.
    @Test func refusesToDeleteAProjectFolder() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        try root.write(session: root.makeSession(title: "Filed", project: "Accurate"),
                       at: "Accurate/2026-08-04 1801 - Filed - Ana")

        #expect(throws: RecordingStore.DeletionError.self) {
            try RecordingStore.deleteSessionFolder(relativePath: "Accurate", recordingsDirectory: root.url)
        }
        #expect(FileManager.default.fileExists(
            atPath: root.url.appendingPathComponent("Accurate/2026-08-04 1801 - Filed - Ana").path))
    }

    @Test func refusesToEscapeTheRecordingsDirectory() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        #expect(throws: RecordingStore.DeletionError.self) {
            try RecordingStore.deleteSessionFolder(relativePath: "../outside", recordingsDirectory: root.url)
        }
        #expect(throws: RecordingStore.DeletionError.self) {
            try RecordingStore.deleteSessionFolder(relativePath: "Accurate/deep/deeper",
                                                   recordingsDirectory: root.url)
        }
    }

    @Test func deletingAnAbsentRecordingIsNotAnError() throws {
        let root = try TemporaryRecordings()
        defer { root.cleanUp() }
        try RecordingStore.deleteSessionFolder(relativePath: "Accurate/gone", recordingsDirectory: root.url)
    }
}

/// A throwaway recordings root, so no test can touch the real library.
private struct TemporaryRecordings {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }

    func makeSession(title: String, project: String?) -> RecordingSession {
        let event = UnifiedEvent(dedupKey: "event-\(title)", title: title,
                                 startTs: Date(timeIntervalSince1970: 1_785_880_800),
                                 endTs: Date(timeIntervalSince1970: 1_785_884_400), isAllDay: false,
                                 status: "confirmed", effectiveResponse: nil, meetingURL: nil,
                                 location: nil, descriptionText: nil, htmlLink: nil,
                                 organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                                 winnerAccountEmail: "a@example.com", projectId: project,
                                 projectConfidence: nil, sourcesJSON: "[]")
        return RecordingSession(event: event, notePath: nil)
    }

    func write(session: RecordingSession, at relativePath: String) throws {
        var folder = url
        for part in relativePath.split(separator: "/") { folder.appendPathComponent(String(part)) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stored = session
        stored.folderPath = relativePath.contains("/") ? relativePath : nil
        try JSONEncoder().encode(stored).write(to: folder.appendingPathComponent("session.json"))
        try Data("audio".utf8).write(to: folder.appendingPathComponent("mic.m4a"))
    }
}
