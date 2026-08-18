import Testing
import Foundation
@testable import HallE

@Suite("Meeting insight contract")
struct MeetingInsightsTests {
    @Test func decodesPromptShapedSnakeCaseJSON() throws {
        let json = """
        {"cleaned_transcript":"Hola","summary":"Resumen","decisions":["Sí"],
        "action_items":[{"task":"Enviar","owner":"Ana","due_date":"2026-07-12","project":null,"confidence":0.9}],
        "follow_ups":["Revisar"],"risks":["Plazo"],"confidence":0.8}
        """
        let value = try #require(JSONExtractor.decode(MeetingInsights.self, from: json))
        #expect(value.cleanedTranscript == "Hola")
        #expect(value.actionItems.first?.task == "Enviar")
        #expect(value.followUps == ["Revisar"])
    }
}
