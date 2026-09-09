import Foundation
import Testing
@testable import HallE

@Suite struct MeetingNotesTests {
    @Test func notesSurviveRelaunchAndStaySeparateFromRecordingArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("notes")
        let recordings = root.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let id = UUID()
        let store = MeetingNotesStore(directory: directory)
        #expect(try store.load(sessionID: id).isEmpty)
        try store.save("Decisión: revisar mañana.\n- [ ] Preparar propuesta", sessionID: id)
        try FileManager.default.removeItem(at: recordings)
        let reloaded = MeetingNotesStore(directory: directory)
        #expect(try reloaded.load(sessionID: id) == "Decisión: revisar mañana.\n- [ ] Preparar propuesta")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.url(for: id).path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try reloaded.load(sessionID: UUID()).isEmpty)
        try reloaded.save("", sessionID: id)
        #expect(try reloaded.load(sessionID: id).isEmpty)
    }

    @Test func exportKeepsUserNotesAndTranscriptDistinct() {
        let markdown = MeetingNotesStore.export(title: "Weekly\nmeeting", date: .distantPast,
                                                notes: "My interpretation", transcript: "[00:01] Actual words")
        #expect(markdown.hasPrefix("# Weekly meeting\n"))
        #expect(markdown.contains("My interpretation"))
        #expect(markdown.contains("[00:01] Actual words"))
    }

    @Test func automaticLocalLanguageFollowsSupportedMacLanguages() {
        #expect(TranscriptionLanguagePreference.localLanguage(preferredLanguages: ["es-CL", "en-US"]) == "es")
        #expect(TranscriptionLanguagePreference.localLanguage(preferredLanguages: ["fr_CA"]) == "fr")
        #expect(TranscriptionLanguagePreference.localLanguage(preferredLanguages: ["ja-JP", "de-DE"]) == "de")
        #expect(TranscriptionLanguagePreference.localLanguage(preferredLanguages: ["ja-JP"]) == "ja")
        #expect(TranscriptionLanguagePreference.localLanguage(preferredLanguages: []) == "en")
        for language in TranscriptionLanguagePreference.allCases where language != .auto {
            #expect(!LocalTranscriptionProvider.candidateLocales(for: language.rawValue).isEmpty)
        }
        #expect(LocalTranscriptionProvider.candidateLocales(for: "unknown").isEmpty)
    }
}
