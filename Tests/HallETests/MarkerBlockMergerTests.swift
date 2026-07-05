import Testing
import Foundation
@testable import HallE

@Suite("MarkerBlockMerger (non-destructive)")
struct MarkerBlockMergerTests {
    @Test func replacesInsideExistingMarkers() {
        let note = """
        # Meeting

        ## Transcript
        <!-- hall-e:transcript:start -->
        <!-- transcript goes here -->
        <!-- hall-e:transcript:end -->

        ## Summary
        user wrote this
        """
        let (out, outcome) = MarkerBlockMerger.merge(
            note: note, section: "transcript", newContent: "Hello world.\nSecond line.",
            headingAnchor: "Transcript", mode: .replace)
        #expect(outcome == .mergedViaMarkers)
        #expect(out.contains("Hello world.\nSecond line."))
        #expect(out.contains("user wrote this"))       // user text untouched
        #expect(!out.contains("transcript goes here"))  // placeholder replaced
    }

    @Test func doubleMergeIsByteIdentical() {
        let note = """
        <!-- hall-e:summary:start -->
        <!-- hall-e:summary:end -->
        """
        let (a, _) = MarkerBlockMerger.merge(note: note, section: "summary",
                                             newContent: "S1", headingAnchor: "Summary", mode: .replace)
        let (b, outcome) = MarkerBlockMerger.merge(note: a, section: "summary",
                                                   newContent: "S1", headingAnchor: "Summary", mode: .replace)
        #expect(a == b)
        #expect(outcome == .unchanged)
    }

    @Test func fallsBackToHeadingWhenMarkersRemoved() {
        // User deleted our markers but kept the "## Transcript" heading and added prose.
        let note = """
        # Meeting

        ## Transcript
        my own notes here

        ## Summary
        keep me
        """
        let (out, outcome) = MarkerBlockMerger.merge(
            note: note, section: "transcript", newContent: "AUTO",
            headingAnchor: "Transcript", mode: .replace)
        #expect(outcome == .mergedViaHeading)
        #expect(out.contains("my own notes here"))  // preserved
        #expect(out.contains("keep me"))            // next section preserved
        #expect(out.contains("<!-- hall-e:transcript:start -->\nAUTO\n<!-- hall-e:transcript:end -->"))
        // The inserted block must sit inside the Transcript section, before "## Summary".
        let idxBlock = out.range(of: "hall-e:transcript:start")!.lowerBound
        let idxSummary = out.range(of: "## Summary")!.lowerBound
        #expect(idxBlock < idxSummary)
    }

    @Test func appendsAtEndWhenNoMarkerNoHeading() {
        let note = "# Meeting\n\nJust some notes."
        let (out, outcome) = MarkerBlockMerger.merge(
            note: note, section: "actions", newContent: "- [ ] do thing",
            headingAnchor: "Action items", mode: .replace)
        #expect(outcome == .appendedAtEnd)
        #expect(out.hasPrefix("# Meeting\n\nJust some notes."))
        #expect(out.contains("## Action items"))
        #expect(out.contains("- [ ] do thing"))
    }

    @Test func appendLinesDedupesAndSortsDescending() {
        let note = """
        <!-- hall-e:meetings-index:start -->
        - 2026-07-01 — [[A|A]]
        <!-- hall-e:meetings-index:end -->
        """
        // Add two lines, one duplicate.
        let (out, _) = MarkerBlockMerger.merge(
            note: note, section: "meetings-index",
            newContent: "- 2026-07-05 — [[B|B]]\n- 2026-07-01 — [[A|A]]",
            headingAnchor: "Meetings", mode: .appendLines, sortDescending: true)
        let interior = out.components(separatedBy: "\n").filter { $0.hasPrefix("- 2026") }
        #expect(interior == ["- 2026-07-05 — [[B|B]]", "- 2026-07-01 — [[A|A]]"])  // sorted desc, deduped
    }

    @Test func corruptedMarkersNeverDeleteUserText() {
        // Start marker present, end marker deleted by the user → must NOT guess extent.
        let note = """
        <!-- hall-e:transcript:start -->
        important user content that must survive
        ## Summary
        more content
        """
        let (out, outcome) = MarkerBlockMerger.merge(
            note: note, section: "transcript", newContent: "NEW",
            headingAnchor: "Transcript", mode: .replace)
        #expect(out.contains("important user content that must survive"))
        #expect(out.contains("more content"))
        #expect(outcome == .appendedAtEnd)  // fell through safely
    }
}

@Suite("FilenameSanitizer + FrontmatterCodec")
struct ObsidianCodecTests {
    @Test func sanitizesIllegalCharsAndAccents() {
        #expect(FilenameSanitizer.sanitize("Accurate: Director/Dashboard Review")
                == "Accurate Director Dashboard Review")
        #expect(FilenameSanitizer.sanitize("Reunión café ☕ Viña Cousiño")
                .contains("Reunión café"))
        #expect(FilenameSanitizer.sanitize("   ") == "Untitled")
    }

    @Test func boundsByByteLength() {
        let long = String(repeating: "a", count: 500)
        #expect(FilenameSanitizer.sanitize(long, maxBytes: 180).utf8.count <= 180)
    }

    @Test func readsAndUpdatesFrontmatterScalars() {
        let note = """
        ---
        type: meeting
        transcript_status: "pending"
        hall_e_event_id: "ical:UID@123"
        ---
        # Body
        """
        #expect(FrontmatterCodec.readValue(note, key: "hall_e_event_id") == "ical:UID@123")
        let updated = FrontmatterCodec.updateValue(note, key: "transcript_status", value: "completed")
        #expect(FrontmatterCodec.readValue(updated, key: "transcript_status") == "completed")
        #expect(updated.contains("# Body"))  // body preserved
    }

    @Test func insertsMissingFrontmatterKey() {
        let note = "---\ntype: meeting\n---\n# X"
        let updated = FrontmatterCodec.updateValue(note, key: "project", value: "Accurate")
        #expect(FrontmatterCodec.readValue(updated, key: "project") == "Accurate")
        #expect(FrontmatterCodec.readValue(updated, key: "type") == "meeting")
    }
}
