import XCTest
@testable import HallE

final class ProjectFollowUpStoreTests: XCTestCase {
    func testLocalCompletionOverrideSurvivesIndexReconstructionAndCanReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("follow-ups.json")
        let original = IndexedActionItem(id: "stable-note-action-id", notePath: "Projects/Atlas/Notes/Decision.md",
                                         eventId: nil, task: "Send the approved plan", owner: "Ana",
                                         dueDate: "2026-10-22", project: "Atlas", isCompleted: false,
                                         confidence: nil, updatedAt: Date())

        var store = ProjectFollowUpStore(fileURL: file)
        XCTAssertFalse(store.isCompleted(original))
        try store.setCompleted(true, for: original.id)

        // A vault reindex creates a fresh value from the untouched note. The
        // separate local state should still win for the stable action identity.
        let reindexed = IndexedActionItem(id: original.id, notePath: original.notePath,
                                          eventId: original.eventId, task: original.task, owner: original.owner,
                                          dueDate: original.dueDate, project: original.project,
                                          isCompleted: false, confidence: nil, updatedAt: Date())
        var reloaded = ProjectFollowUpStore(fileURL: file)
        XCTAssertTrue(reloaded.isCompleted(reindexed))

        try reloaded.setCompleted(false, for: reindexed.id)
        reloaded = ProjectFollowUpStore(fileURL: file)
        XCTAssertFalse(reloaded.isCompleted(reindexed))
        XCTAssertEqual(reindexed.task, "Send the approved plan")
    }

    func testCorruptStateIsReportedAndNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("follow-ups.json")
        let corruptData = Data("{ not valid json".utf8)
        try corruptData.write(to: file)

        var store = ProjectFollowUpStore(fileURL: file)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.setCompleted(true, for: "action-id"))
        XCTAssertEqual(try Data(contentsOf: file), corruptData)
    }
}
