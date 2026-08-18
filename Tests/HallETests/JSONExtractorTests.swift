import Testing
import Foundation
@testable import HallE

@Suite("JSONExtractor")
struct JSONExtractorTests {
    struct Sample: Codable, Equatable { let project: String?; let confidence: Double }

    @Test func extractsBareObject() {
        let r = JSONExtractor.decode(Sample.self, from: #"{"project":"Accurate","confidence":0.9}"#)
        #expect(r == Sample(project: "Accurate", confidence: 0.9))
    }

    @Test func stripsCodeFences() {
        let raw = "```json\n{\"project\":\"Oasis\",\"confidence\":0.8}\n```"
        #expect(JSONExtractor.decode(Sample.self, from: raw)?.project == "Oasis")
    }

    @Test func ignoresSurroundingProse() {
        let raw = "Sure! Here is the JSON you asked for:\n{\"project\":null,\"confidence\":0.1}\nHope that helps."
        let r = JSONExtractor.decode(Sample.self, from: raw)
        #expect(r?.project == nil)
        #expect(r?.confidence == 0.1)
    }

    @Test func repairsTrailingCommaAndSmartQuotes() {
        let raw = "{\u{201C}project\u{201D}:\u{201C}Rumbo\u{201D},\u{201C}confidence\u{201D}:0.7,}"
        let r = JSONExtractor.decode(Sample.self, from: raw)
        #expect(r?.project == "Rumbo")
    }

    @Test func handlesBracesInsideStrings() {
        let raw = #"{"project":"A {weird} name","confidence":0.5}"#
        let r = JSONExtractor.decode(Sample.self, from: raw)
        #expect(r?.project == "A {weird} name")
    }

    @Test func returnsNilForNonJSON() {
        #expect(JSONExtractor.extractObject("I cannot help with that.") == nil)
    }

    @Test func extractsFirstOfNestedCorrectly() {
        let raw = #"prefix {"project":"X","confidence":0.6,"meta":{"a":1}} suffix"#
        let r = JSONExtractor.decode(Sample.self, from: raw)
        #expect(r?.project == "X")
    }
}

@Suite("JSONExtractor hardening")
struct JSONExtractorHardeningTests {
    struct Sample: Codable, Equatable { let project: String?; let confidence: Double }

    @Test func skipsStrayObjectBeforePayload() {
        let raw = #"Reasoning: {} and also {"note":"irrelevant"} → {"project":"X","confidence":0.6}"#
        let r = JSONExtractor.decode(Sample.self, from: raw)
        #expect(r?.project == "X")
    }

    @Test func preservesCommaBracketInsideStrings() {
        let raw = #"{"project":"weird ,] name","confidence":0.2,}"#
        let r = JSONExtractor.decode(Sample.self, from: raw)
        #expect(r?.project == "weird ,] name")
    }

    @Test func preservesSmartQuotesInsideStringValues() {
        let raw = "{\"project\":\"a \u{201C}quoted\u{201D} word\",\"confidence\":0.3}"
        let r = JSONExtractor.decode(Sample.self, from: raw)
        #expect(r?.project == "a \u{201C}quoted\u{201D} word")
    }
}
