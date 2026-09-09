import Foundation
import Testing
@testable import HallE

@Suite struct PublicWorkspaceTests {
    @Test func freshWorkspaceStartsEmptyAndCorruptFileSurvives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("projects.json")
        #expect(AliasStore(fileURL: file).projects.isEmpty)
        let corrupt = Data("unreadable project data".utf8)
        try corrupt.write(to: file)
        #expect(AliasStore(fileURL: file).projects.isEmpty)
        #expect(try Data(contentsOf: file) == corrupt)
    }

    @Test func displayAndCopyRetainSpeakersAndTimestamps() {
        let transcript = Transcript(sessionID: UUID(), localeUsed: "en", segments: [
            .init(start: 0, duration: 1, text: "Hello", track: "mixed", speaker: 0),
            .init(start: 3661, duration: 1, text: "Hi", track: "mixed", speaker: 1)
        ], status: .completed, source: "deepgram:nova-3")
        #expect(transcript.speakerLabeledText == "[00:00:00] Speaker 1: Hello\n\n[01:01:01] Speaker 2: Hi")
        #expect(transcript.plainText == "Hello Hi")
    }
}
