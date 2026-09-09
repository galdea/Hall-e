import Foundation
import Testing
@testable import HallE

@Suite("Notes without Obsidian")
struct LocalNoteOpenerTests {
    @Test func resolvesMarkdownNameWithoutURLEncodingOrDroppingExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try #require(LocalNoteOpener.noteURL(root: root, relativePath: "Hall-e/Meetings/Revisión & A+B.md"))
        #expect(note.isFileURL)
        #expect(note.lastPathComponent == "Revisión & A+B.md")
        #expect(note.pathExtension == "md")
    }

    @Test func rejectsPathsOutsideNotesFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(LocalNoteOpener.noteURL(root: root, relativePath: "../outside.md") == nil)
        #expect(LocalNoteOpener.noteURL(root: root, relativePath: "/outside.md") == nil)
        #expect(LocalNoteOpener.noteURL(root: root, relativePath: "") == nil)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"),
                                                  withDestinationURL: root.deletingLastPathComponent())
        #expect(LocalNoteOpener.noteURL(root: root, relativePath: "escape/outside.md") == nil)
    }
}
