import Testing
import Foundation
@testable import HallE

@Suite("Project source importers")
struct ProjectSourceImporterTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("halle-import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func codexImporterScopesByCWDAndExcludesInjectedContext() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let sessions = root.appendingPathComponent("codex/sessions/2026/07/10", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "session-1", "cwd": project.path,
                                                    "timestamp": "2026-07-10T10:00:00Z"]],
            ["type": "response_item", "payload": ["role": "user", "content": [
                ["type": "input_text", "text": "Implement the dashboard"]]]],
            ["type": "response_item", "payload": ["role": "user", "content": [
                ["type": "input_text", "text": "Use API_KEY=super-secret-value"]]]],
            ["type": "response_item", "payload": ["role": "assistant", "content": [
                ["type": "output_text", "text": "Dashboard implemented with tests."]]]],
            ["type": "response_item", "payload": ["role": "user", "content": [
                ["type": "input_text", "text": "<environment_context>secret internals</environment_context>"]]]],
            ["type": "response_item", "payload": ["role": "tool", "content": [
                ["type": "output_text", "text": "API_KEY=secret"]]]],
        ]
        let jsonl = try lines.map { value in
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }.joined(separator: "\n")
        try jsonl.write(to: sessions.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)

        let importer = CodexSessionImporter(codexHome: root.appendingPathComponent("codex"))
        let documents = try importer.load(from: project)
        #expect(documents.count == 1)
        #expect(documents[0].body.contains("Implement the dashboard"))
        #expect(documents[0].body.contains("Dashboard implemented"))
        #expect(!documents[0].body.contains("secret internals"))
        #expect(!documents[0].body.contains("API_KEY"))
        #expect(!documents[0].body.contains("super-secret-value"))
    }

    @Test func chatGPTImporterReadsConversationGraph() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let export = folder.appendingPathComponent("conversations.json")
        let value: [[String: Any]] = [[
            "id": "chat-1", "title": "Launch plan", "create_time": 1_800_000_000.0,
            "mapping": [
                "one": ["message": ["create_time": 1.0, "author": ["role": "user"],
                                      "content": ["parts": ["What ships next?"]]]],
                "two": ["message": ["create_time": 2.0, "author": ["role": "assistant"],
                                      "content": ["parts": ["Ship the calendar player."]]]],
                "system": ["message": ["create_time": 0.0, "author": ["role": "system"],
                                         "content": ["parts": ["hidden instructions"]]]],
            ],
        ]]
        try JSONSerialization.data(withJSONObject: value).write(to: export)
        let documents = try ChatGPTExportImporter().load(from: export)
        #expect(documents.count == 1)
        #expect(documents[0].externalId == "chat-1")
        #expect(documents[0].body.contains("What ships next?"))
        #expect(documents[0].body.contains("Ship the calendar player."))
        #expect(!documents[0].body.contains("hidden instructions"))
    }

    @Test func whatsAppImporterHandlesMultilineMessagesAndStableIDs() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let export = folder.appendingPathComponent("Project Group.txt")
        let text = """
        [10/07/2026, 14:03] Ana: Terminamos el diseño
        y ya está listo para revisión.
        10/07/2026, 14:05 - Gabriel: Próximo paso: publicar
        """
        try text.write(to: export, atomically: true, encoding: .utf8)
        let first = try WhatsAppExportImporter().load(from: export)
        let second = try WhatsAppExportImporter().load(from: export)
        #expect(first.count == 2)
        #expect(first[0].body.contains("listo para revisión"))
        #expect(first.map(\.externalId) == second.map(\.externalId))
        #expect(first[1].author == "Gabriel")
    }
}
