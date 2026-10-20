import XCTest
@testable import HallE

final class VaultIndexActionIdentityTests: XCTestCase {
    private func document(path: String = "Projects/Atlas/Decision.md", body: String) -> VaultDocument {
        VaultDocument(path: path, title: "Decision", type: nil, project: "Atlas", eventId: nil,
                      contentHash: "test", modifiedAt: Date(), body: body)
    }

    func testIdentityIgnoresCheckboxStateAndUnrelatedLineOffsets() {
        let before = document(body: """
        # Decision
        <!-- hall-e:actions:start -->
        - [ ] Send the approved plan
        <!-- hall-e:actions:end -->
        """)
        let after = document(body: """
        # Decision
        Context line added before the action.
        <!-- hall-e:actions:start -->
        - [x] Send the approved plan
        <!-- hall-e:actions:end -->
        """)

        let beforeID = VaultIndex.parseActionItems(from: before).first?.id
        let afterID = VaultIndex.parseActionItems(from: after).first?.id
        XCTAssertEqual(beforeID, afterID)
    }

    func testDuplicateTasksReceiveDistinctStableOrdinals() {
        let initial = document(body: """
        <!-- hall-e:actions:start -->
        - [ ] Send the approved plan
        - [ ] Send the approved plan
        <!-- hall-e:actions:end -->
        """)
        let shifted = document(body: """
        <!-- hall-e:actions:start -->
        - [ ] Unrelated task
        - [ ] Send the approved plan
        - [ ] Send the approved plan
        <!-- hall-e:actions:end -->
        """)

        let first = VaultIndex.parseActionItems(from: initial)
        let second = VaultIndex.parseActionItems(from: shifted)
        XCTAssertEqual(first.count, 2)
        XCTAssertNotEqual(first[0].id, first[1].id)
        XCTAssertEqual(Array(first.map(\.id)), Array(second.suffix(2).map(\.id)))
    }

    func testIdentityChangesWhenNoteMovesOrTaskIsEdited() {
        let base = document(body: """
        <!-- hall-e:actions:start -->
        - [ ] Send the approved plan
        <!-- hall-e:actions:end -->
        """)
        let moved = document(path: "Projects/Atlas/Archive/Decision.md", body: base.body)
        let edited = document(body: """
        <!-- hall-e:actions:start -->
        - [ ] Send the final approved plan
        <!-- hall-e:actions:end -->
        """)

        let id = VaultIndex.parseActionItems(from: base).first?.id
        XCTAssertNotEqual(id, VaultIndex.parseActionItems(from: moved).first?.id)
        XCTAssertNotEqual(id, VaultIndex.parseActionItems(from: edited).first?.id)
    }
}
