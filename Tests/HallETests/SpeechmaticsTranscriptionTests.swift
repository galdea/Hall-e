import Foundation
import Testing
@testable import HallE

@Suite(.serialized)
struct SpeechmaticsTranscriptionTests {
    @Test func requestUsesMeliaMultilingualSpeakerContract() throws {
        let config = SpeechmaticsConfiguration(region: .us1)
        let data = try config.jobConfig(reference: "session-fingerprint")
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transcription = try #require(root["transcription_config"] as? [String: Any])
        #expect(transcription["model"] as? String == "melia-1")
        #expect(transcription["language"] as? String == "multi")
        #expect(transcription["language_hints"] == nil)
        #expect(!SpeechmaticsRegion.au1.isSupported)
        #expect(SpeechmaticsRegion.supportedRegions == [.us1, .eu1])
        #expect(transcription["diarization"] as? String == "speaker")
        let diarization = try #require(transcription["speaker_diarization_config"] as? [String: Any])
        #expect(diarization["prefer_current_speaker"] as? Bool == true)
        #expect(config.endpoint.host == "us1.asr.api.speechmatics.com")
    }

    @Test func normalizedTranscriptMapsAnonymousSpeakersAndPunctuation() throws {
        let json = #"""
        {
          "format":"2.9",
          "job":{"id":"sm-job-1"},
          "results":[
            {"type":"word","start_time":0.0,"end_time":0.4,"alternatives":[{"content":"Hola","confidence":0.99,"language":"es","speaker":"S7"}]},
            {"type":"punctuation","start_time":0.4,"end_time":0.4,"attaches_to":"previous","is_eos":true,"alternatives":[{"content":".","confidence":1,"language":"es","speaker":"S7"}]},
            {"type":"word","start_time":0.8,"end_time":1.1,"alternatives":[{"content":"Hello","confidence":0.98,"language":"en","speaker":"S2"}]},
            {"type":"word","start_time":1.1,"end_time":1.4,"alternatives":[{"content":"team","confidence":0.97,"language":"en","speaker":"S2"}]},
            {"type":"punctuation","start_time":1.4,"end_time":1.4,"attaches_to":"previous","is_eos":true,"alternatives":[{"content":"!","confidence":1,"language":"en","speaker":"S2"}]}
          ]
        }
        """#
        let response = try JSONDecoder().decode(SpeechmaticsTranscriptResponse.self, from: Data(json.utf8))
        let provider = SpeechmaticsTranscriptionProvider(configuration: .init(region: .us1),
                                                         rawResponseDirectory: FileManager.default.temporaryDirectory,
                                                         duration: 2)
        let transcript = try provider.normalize(response, sessionID: UUID(), track: "mixed", digest: "abc")
        #expect(transcript.segments.map(\.speaker) == [0, 1])
        #expect(transcript.segments.map(\.text) == ["Hola.", "Hello team!"])
        #expect(transcript.words?.map(\.punctuatedWord) == ["Hola.", "Hello", "team!"])
        #expect(transcript.providerMetadata?.requestID == "sm-job-1")
        #expect(transcript.source == "speechmatics:melia-1")
    }

    @Test func speechWithoutDiarizationCannotReplaceTranscript() throws {
        let json = #"""
        {"format":"2.9","job":{"id":"job"},"results":[
          {"type":"word","start_time":0,"end_time":1,"alternatives":[{"content":"speech","confidence":1,"speaker":"UU"}]}
        ]}
        """#
        let response = try JSONDecoder().decode(SpeechmaticsTranscriptResponse.self, from: Data(json.utf8))
        let provider = SpeechmaticsTranscriptionProvider(configuration: .init(region: .us1),
                                                         rawResponseDirectory: FileManager.default.temporaryDirectory,
                                                         duration: 1)
        #expect(throws: SpeechmaticsError.self) {
            try provider.normalize(response, sessionID: UUID(), track: "mixed", digest: "abc")
        }
    }

    @Test func legacySpendEntriesDecodeAsDeepgram() throws {
        let json = #"""
        {"schemaVersion":1,"entries":[{
          "fingerprint":"old","month":"2026-08","estimatedUSD":1.2,
          "state":"completed","requestID":"req","updatedAt":0
        }]}
        """#
        let ledger = try JSONDecoder().decode(CloudTranscriptionSpendLedgerDocument.self,
                                              from: Data(json.utf8))
        #expect(ledger.entries.first?.provider == .deepgram)
        #expect(ledger.entries.first?.rateUSDPerHour == nil)
    }

    @Test func legacyCloudCheckpointDecodesWithoutProviderFields() throws {
        let json = #"""
        {"schemaVersion":1,"state":"uploading","requestFingerprint":"old",
         "estimatedCostUSD":1,"updatedAt":0}
        """#
        let checkpoint = try JSONDecoder().decode(CloudTranscriptionJob.self, from: Data(json.utf8))
        #expect(checkpoint.provider == nil)
        #expect(checkpoint.phase == nil)
        #expect(checkpoint.providerJobID == nil)
        #expect(checkpoint.providerRegion == nil)
    }

    @Test func speechmaticsConsentIsBoundToTheSelectedRegion() {
        let priorRegion = AppPreferences.speechmaticsRegion
        let priorTraining = AppPreferences.speechmaticsModelTrainingConfirmedOff
        let priorConsent = AppPreferences.speechmaticsAudioConsent
        defer {
            AppPreferences.speechmaticsRegion = priorRegion
            AppPreferences.speechmaticsModelTrainingConfirmedOff = priorTraining
            AppPreferences.speechmaticsAudioConsent = priorConsent
        }

        AppPreferences.speechmaticsRegion = .us1
        AppPreferences.speechmaticsModelTrainingConfirmedOff = true
        AppPreferences.speechmaticsAudioConsent = .grant(
            processor: SpeechmaticsRegion.us1.consentProcessor, purpose: "test")
        #expect(AppPreferences.allowSpeechmaticsAudioTranscription)

        AppPreferences.speechmaticsRegion = .eu1
        #expect(!AppPreferences.allowSpeechmaticsAudioTranscription)
    }
}
