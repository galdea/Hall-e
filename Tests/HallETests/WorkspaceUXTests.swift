import Testing
import Foundation
@testable import HallE

@Suite("Workspace UX contracts")
struct WorkspaceUXTests {
    @Test func routesHaveStableIdentityAndPresentation() {
        #expect(WorkspaceRoute.allCases.map(\.rawValue) == ["today", "inbox", "projects", "meetings", "actions", "people", "search"])
        for route in WorkspaceRoute.allCases {
            #expect(!route.title.isEmpty)
            #expect(!route.symbol.isEmpty)
        }
    }

    @Test func projectPreviewExcludesRawTranscriptByDefault() {
        let project = Project(id: "p1", name: "Project One", aliases: [])
        let body = """
        # Meeting
        Public decision
        <!-- hall-e:transcript:start -->
        private raw words
        <!-- hall-e:transcript:end -->
        """
        let document = VaultDocument(path: "Meetings/one.md", title: "Meeting", type: "meeting",
                                     project: project.name, eventId: "m1", contentHash: "hash",
                                     modifiedAt: Date(), body: body)
        let service = ProjectContextService()
        let output = service.markdown(project: project, documents: [document], actions: [])
        let preview = service.preview(project: project, documents: [document], actions: [])
        #expect(output.contains("Public decision"))
        #expect(!output.contains("private raw words"))
        #expect(!preview.includesTranscripts)
        #expect(preview.documentCount == 1)
        #expect(preview.sourcePaths == ["Meetings/one.md"])
    }

    @Test func projectPreviewHonorsBoundedExportOptions() {
        let project = Project(id: "p1", name: "Project One", aliases: [])
        let documents = (0..<4).map { index in
            VaultDocument(path: "note-\(index).md", title: "Note \(index)", type: nil,
                          project: project.name, eventId: nil, contentHash: "\(index)",
                          modifiedAt: Date(), body: "Body \(index)")
        }
        var options = ProjectContextExportOptions()
        options.maximumDocuments = 2
        let preview = ProjectContextService().preview(project: project, documents: documents,
                                                      actions: [], options: options)
        #expect(preview.documentCount == 2)
        #expect(preview.sourcePaths.count == 2)
    }

    @Test func englishAndSpanishResourcesResolve() {
        let old = AppPreferences.appLanguage
        defer { AppPreferences.appLanguage = old }
        AppPreferences.appLanguage = "en"
        #expect(L10n.text("workspace.today") == "Today")
        AppPreferences.appLanguage = "es"
        #expect(L10n.text("workspace.today") == "Hoy")
    }

    @Test func quietHoursCrossMidnight() {
        let oldStart = AppPreferences.quietHoursStart, oldEnd = AppPreferences.quietHoursEnd
        defer { AppPreferences.quietHoursStart = oldStart; AppPreferences.quietHoursEnd = oldEnd }
        AppPreferences.quietHoursStart = 22; AppPreferences.quietHoursEnd = 8
        var components = DateComponents(); components.calendar = Calendar(identifier: .gregorian)
        components.year = 2026; components.month = 7; components.day = 10
        components.hour = 23
        #expect(AppPreferences.isQuietHour(components.date!))
        components.hour = 12
        #expect(!AppPreferences.isQuietHour(components.date!))
    }
}
