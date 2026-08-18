import Testing
import Foundation
@testable import HallE

@Suite("Chunk overlap dedup")
struct TranscriptionDedupTests {
    private func word(_ text: String, at start: TimeInterval, dur: TimeInterval = 0.4) -> TranscriptSegment {
        TranscriptSegment(start: start, duration: dur, text: text, track: "mic")
    }

    @Test func allWordsKeptUsesFormattedString() {
        let words = [word("hello", at: 0), word("world", at: 0.5)]
        let text = LocalTranscriptionProvider.blockText(formatted: "Hello, world.",
                                                        words: words, keptIndices: [0, 1])
        #expect(text == "Hello, world.")
    }

    @Test func droppedOverlapWordsAreRemovedFromText() {
        // Chunk starting at 238s with a 2s overlap (cutoff 240): the first two
        // words repeat the previous chunk's tail and must not appear again.
        let words = [word("previous", at: 238.2), word("tail", at: 238.9),
                     word("fresh", at: 240.3), word("speech", at: 240.9)]
        let kept = [2, 3]
        let text = LocalTranscriptionProvider.blockText(formatted: "previous tail fresh speech",
                                                        words: words, keptIndices: kept)
        #expect(text == "fresh speech")
    }

    @Test func fallsBackToSubstringsWhenTokensDontAlign() {
        // formattedString token count differs from segment count → join raw words.
        let words = [word("can't", at: 0), word("stop", at: 0.5), word("now", at: 1.0)]
        let text = LocalTranscriptionProvider.blockText(formatted: "Cannot stop now, really.",
                                                        words: words, keptIndices: [1, 2])
        #expect(text == "stop now")
    }
}
