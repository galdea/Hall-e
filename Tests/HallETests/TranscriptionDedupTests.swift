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

    @Test func meaningfulSpeechAcrossTracksIgnoresBlankTrackButRejectsAllBlank() {
        let blankSystem = TranscriptSegment(start: 0, duration: 0, text: " \n ", track: "system")
        let spokenMic = TranscriptSegment(start: 0, duration: 1.2, text: "Hello there.", track: "mic")
        #expect(!LocalTranscriptionProvider.hasMeaningfulText(in: [blankSystem]))
        #expect(LocalTranscriptionProvider.hasMeaningfulText(in: [blankSystem, spokenMic]))
    }

    private func snapshot(_ text: String, words: [TranscriptSegment]) -> LocalTranscriptionProvider.ChunkResult {
        return LocalTranscriptionProvider.ChunkResult(words: words, formatted: text)
    }

    private func snapshot(_ text: String, word: String) -> LocalTranscriptionProvider.ChunkResult {
        snapshot(text, words: [self.word(word, at: 0.1, dur: 0.3)])
    }

    @Test func meaningfulFinalWinsOverEarlierPartial() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        #expect(policy.consume(.partial(snapshot("first thought", word: "first"))) == .awaiting)
        let final = snapshot("Correct final sentence.", word: "Correct")
        #expect(policy.consume(.final(final)) == .recognized(final))
    }

    @Test func emptyFinalUsesLatestMeaningfulPartialWithoutConcatenating() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        #expect(policy.consume(.partial(snapshot("first version", word: "first"))) == .awaiting)
        let latest = snapshot("This is the complete sentence.", word: "This")
        #expect(policy.consume(.partial(latest)) == .awaiting)
        #expect(policy.consume(.partial(snapshot("  ", word: "  "))) == .awaiting)
        #expect(policy.consume(.final(snapshot("", word: ""))) == .recognized(latest))
        #expect(policy.consume(.final(snapshot("late final", word: "late"))) == .ignored)
    }

    @Test func emptyFinalWithoutMeaningfulPartialIsAnEmptySuccess() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        #expect(policy.consume(.partial(snapshot(" \n ", word: " "))) == .awaiting)
        #expect(policy.consume(.final(snapshot("", word: ""))) == .empty)
    }

    private func provisionalGridSnapshot(wordCount: Int = 18,
                                         startingAt start: TimeInterval = 0) -> LocalTranscriptionProvider.ChunkResult {
        let words = (0..<wordCount).map { index in
            word("placeholder", at: start + Double(index) * 0.011, dur: 0.011)
        }
        return snapshot(Array(repeating: "placeholder", count: wordCount).joined(separator: " "), words: words)
    }

    @Test func provisionalElevenMillisecondGridIsIgnoredBeforeRealGroupedSegments() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let real = snapshot(
            "This is a test to my Mac the map keeps the transcript is deleted after transcript and verified",
            words: [
                word("This is", at: 4.14, dur: 1.11),
                word("a test to my Mac the map keeps the", at: 5.25, dur: 4.23),
                word("transcript is deleted after transcript and verified", at: 9.48, dur: 4.80)
            ])
        #expect(policy.consume(.partial(provisionalGridSnapshot(wordCount: 1))) == .awaiting)
        #expect(policy.consume(.partial(provisionalGridSnapshot(wordCount: 2))) == .awaiting)
        #expect(policy.consume(.partial(provisionalGridSnapshot(wordCount: 3))) == .awaiting)
        #expect(policy.consume(.partial(real)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .recognized(real))
    }

    @Test func provisionalElevenMillisecondGridCannotBePromotedAtEmptyFinal() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        #expect(policy.consume(.partial(provisionalGridSnapshot(wordCount: 1))) == .awaiting)
        #expect(policy.consume(.partial(provisionalGridSnapshot(wordCount: 2))) == .awaiting)
        #expect(policy.consume(.partial(provisionalGridSnapshot(wordCount: 3))) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .empty)
    }

    @Test func provisionalGridAfterRealPrefixMakesEmptyFinalRetryable() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let prefix = snapshot("The opening words.", words: [
            word("The", at: 0), word("opening", at: 0.5), word("words", at: 1.0)
        ])
        #expect(policy.consume(.partial(prefix)) == .awaiting)
        #expect(policy.consume(.partial(provisionalGridSnapshot(startingAt: 8.0))) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .failed(
            "Speech returned incomplete results. Your recording is saved; try transcription again."))
    }

    @Test func laterCompleteRealSnapshotClearsPendingProvisionalRevision() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let prefix = snapshot("The opening words.", words: [
            word("The", at: 0), word("opening", at: 0.5), word("words", at: 1.0)
        ])
        let complete = snapshot("The complete sentence reaches its final word.", words: [
            word("The", at: 0), word("complete", at: 0.5), word("sentence", at: 1.0),
            word("reaches", at: 5.0), word("its", at: 5.5), word("final", at: 6.0),
            word("word", at: 6.5)
        ])
        #expect(policy.consume(.partial(prefix)) == .awaiting)
        #expect(policy.consume(.partial(provisionalGridSnapshot(startingAt: 8.0))) == .awaiting)
        #expect(policy.consume(.partial(complete)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .recognized(complete))
    }

    @Test func fullerPrefixAndTailSurvivesLaterTailOnlySnapshot() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let fuller = snapshot("The phone sends audio, and the Mac saves it.", words: [
            word("The", at: 0.0), word("phone", at: 0.5), word("sends", at: 1.0),
            word("audio", at: 1.5), word("Mac", at: 8.0), word("saves", at: 8.5),
            word("it", at: 9.0)
        ])
        let tail = snapshot("the Mac saves it", words: [
            word("Mac", at: 8.0), word("saves", at: 8.5), word("it", at: 9.0)
        ])
        #expect(policy.consume(.partial(fuller)) == .awaiting)
        #expect(policy.consume(.partial(tail)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .recognized(fuller))
    }

    @Test func olderSnapshotThatCoversObservedUnionBeatsLongerTailDroppingSnapshot() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let complete = snapshot("Prefix and tail.", words: [
            word("Prefix", at: 1.0, dur: 1.0), word("tail", at: 10.0, dur: 0.1)
        ])
        let tailDropping = snapshot("Expanded prefix only.", words: [word("Expanded", at: 0.8, dur: 1.4)])
        #expect(policy.consume(.partial(complete)) == .awaiting)
        #expect(policy.consume(.partial(tailDropping)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .recognized(complete))
    }

    @Test func newerFullUnionSnapshotWinsEvenWithLowerMeasuredDuration() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let earlier = snapshot("First version.", words: [
            word("First", at: 1.0, dur: 1.0), word("version", at: 10.0, dur: 0.1)
        ])
        let fullUnionRevision = snapshot("Revised full sentence.", words: [
            word("Revised", at: 1.2, dur: 0.6), word("sentence", at: 10.2, dur: 0.4)
        ])
        #expect(policy.consume(.partial(earlier)) == .awaiting)
        #expect(policy.consume(.partial(fullUnionRevision)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .recognized(fullUnionRevision))
    }

    @Test func newerRevisionWinsWhenTemporalCoverageTies() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let earlier = snapshot("The phone send audio.", words: [
            word("The", at: 0), word("phone", at: 0.5), word("send", at: 1.0), word("audio", at: 1.5)
        ])
        let newer = snapshot("The phone sends audio.", words: [
            word("The", at: 0), word("phone", at: 0.5), word("sends", at: 1.0), word("audio", at: 1.5)
        ])
        #expect(policy.consume(.partial(earlier)) == .awaiting)
        #expect(policy.consume(.partial(newer)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .recognized(newer))
    }

    @Test func disjointPartialSnapshotsCannotBePromotedAtEmptyFinal() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let prefix = snapshot("The phone sends audio.", words: [word("The", at: 0), word("audio", at: 1.0)])
        let tail = snapshot("after the transcript", words: [word("transcript", at: 10.0)])
        #expect(policy.consume(.partial(prefix)) == .awaiting)
        #expect(policy.consume(.partial(tail)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .failed(
            "Speech returned incomplete results. Your recording is saved; try transcription again."))
    }

    @Test func completeCumulativePartialResolvesEarlierFragmentation() {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        let prefix = snapshot("The phone sends audio.", words: [word("The", at: 0), word("audio", at: 1.0)])
        let tail = snapshot("after the transcript", words: [word("transcript", at: 10.0)])
        let complete = snapshot("The phone sends audio after the transcript.", words: [
            word("The", at: 0), word("phone", at: 0.5), word("sends", at: 0.8),
            word("audio", at: 1.0), word("after", at: 9.5), word("the", at: 10.0),
            word("transcript", at: 10.5)
        ])
        #expect(policy.consume(.partial(prefix)) == .awaiting)
        #expect(policy.consume(.partial(tail)) == .awaiting)
        #expect(policy.consume(.partial(complete)) == .awaiting)
        #expect(policy.consume(.final(snapshot("", words: []))) == .recognized(complete))
    }

    @Test(arguments: [
        LocalTranscriptionProvider.RecognitionCallbackPolicy.Event.failed("service error"),
        .cancelled,
        .deadline
    ])
    func failuresNeverPromoteCachedPartial(event: LocalTranscriptionProvider.RecognitionCallbackPolicy.Event) {
        var policy = LocalTranscriptionProvider.RecognitionCallbackPolicy()
        #expect(policy.consume(.partial(snapshot("unfinished hypothesis", word: "unfinished"))) == .awaiting)
        if case .failed(let message) = event {
            #expect(policy.consume(event) == .failed(message))
        } else {
            #expect(policy.consume(event).isFailure)
        }
        #expect(policy.consume(.final(snapshot("", word: ""))) == .ignored)
    }
}

private extension LocalTranscriptionProvider.RecognitionCallbackPolicy.Decision {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
