import Foundation
import Testing
@testable import HallE

struct CloudFallbackPolicyTests {
    private let ready = CloudFallbackPolicy.Availability(
        deepgramConfigured: true, deepgramConsented: true,
        speechmaticsConfigured: true, speechmaticsConsented: true)

    private func checkpoint(provider: CloudTranscriptionProvider? = nil,
                            state: CloudTranscriptionState = .actionRequired,
                            phase: CloudTranscriptionPhase? = nil,
                            jobID: String? = nil) -> CloudTranscriptionJob {
        .init(state: state, requestFingerprint: "test", estimatedCostUSD: 0,
              updatedAt: Date(timeIntervalSince1970: 0), provider: provider,
              phase: phase, providerJobID: jobID)
    }

    @Test func automaticSelectionRequiresEachProvidersOwnConfigurationAndConsent() {
        for dgKey in [false, true] {
            for dgConsent in [false, true] {
                for smConfiguration in [false, true] {
                    for smConsent in [false, true] {
                        let availability = CloudFallbackPolicy.Availability(
                            deepgramConfigured: dgKey, deepgramConsented: dgConsent,
                            speechmaticsConfigured: smConfiguration, speechmaticsConsented: smConsent)
                        let expected: SolvedTranscriptionEngine = !(dgKey && dgConsent)
                            && smConfiguration && smConsent ? .speechmatics : .deepgram
                        #expect(TranscriptionEngineResolver.resolve(
                            preference: .auto, language: .spanish, availability: availability) == expected)
                    }
                }
            }
        }
    }

    @Test func onlyDefiniteExhaustedCreditFallsBack() {
        #expect(CloudFallbackPolicy.fallback(
            preference: .auto, failedEngine: .deepgram,
            error: DeepgramError.creditExhausted("Trial credit exhausted"), availability: ready) == .speechmatics)
        let failures: [Error] = [
            DeepgramError.consentRequired, DeepgramError.missingAPIKey,
            DeepgramError.spendLimitExceeded(projected: 11, limit: 10),
            DeepgramError.actionRequired(status: 403, code: "forbidden"),
            DeepgramError.actionRequired(status: 402, code: nil),
            DeepgramError.ambiguousBilling("Lost response"),
            DeepgramError.retryable(status: nil, retryAfter: nil, message: "Upload unknown"),
            DeepgramError.retryable(status: 429, retryAfter: nil, message: "Rate limit"),
            DeepgramError.retryable(status: 503, retryAfter: nil, message: "Unavailable"),
            DeepgramError.invalidResponse("Invalid transcript"),
            URLError(.networkConnectionLost),
            CloudTranscriptionSpendError.limitExceeded(projected: 11, limit: 10),
            SpeechmaticsError.rejected("Rejected")
        ]
        for error in failures {
            #expect(CloudFallbackPolicy.fallback(preference: .auto, failedEngine: .deepgram,
                                                 error: error, availability: ready) == nil)
        }
    }

    @Test func fallbackRequiresSpeechmaticsConfigurationAndConsent() {
        for configured in [false, true] {
            for consented in [false, true] {
                var availability = ready
                availability.speechmaticsConfigured = configured
                availability.speechmaticsConsented = consented
                #expect((CloudFallbackPolicy.fallback(
                    preference: .auto, failedEngine: .deepgram,
                    error: DeepgramError.creditExhausted("Exhausted"), availability: availability) != nil)
                    == (configured && consented))
            }
        }
    }

    @Test func explicitEnginesNeverFallbackOrChangeSelection() {
        for preference in [TranscriptionEnginePreference.deepgram, .speechmatics, .sfSpeech] {
            #expect(CloudFallbackPolicy.fallback(
                preference: preference, failedEngine: .deepgram,
                error: DeepgramError.creditExhausted("Exhausted"), availability: ready) == nil)
        }
        for availability in [ready, .init()] {
            #expect(TranscriptionEngineResolver.resolve(preference: .deepgram, language: .auto,
                                                        availability: availability) == .deepgram)
            #expect(TranscriptionEngineResolver.resolve(preference: .speechmatics, language: .auto,
                                                        availability: availability) == .speechmatics)
            #expect(TranscriptionEngineResolver.resolve(preference: .sfSpeech, language: .english,
                                                        availability: availability) == .sfSpeech(language: "en"))
        }
    }

    @Test func speechmaticsRetryCannotLoopBackToDeepgram() {
        let saved = checkpoint(provider: .speechmatics, state: .retryableFailure)
        #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .auto,
                                                    availability: ready, checkpoint: saved) == .speechmatics)
        #expect(CloudFallbackPolicy.fallback(
            preference: .auto, failedEngine: .speechmatics,
            error: DeepgramError.creditExhausted("Exhausted"), availability: ready) == nil)
        #expect(CloudFallbackPolicy.fallback(
            preference: .auto, failedEngine: .deepgram,
            error: DeepgramError.creditExhausted("Exhausted"), availability: ready,
            checkpoint: saved) == nil)
    }

    @Test func deepgramRetryDoesNotSwitchWhenItsConfigurationChanges() {
        let speechmaticsOnly = CloudFallbackPolicy.Availability(
            speechmaticsConfigured: true, speechmaticsConsented: true)
        let providers: [CloudTranscriptionProvider?] = [nil, .deepgram]
        for provider in providers {
            for state in [CloudTranscriptionState.retryableFailure, .actionRequired, .ambiguousBilling] {
                #expect(TranscriptionEngineResolver.resolve(
                    preference: .auto, language: .auto, availability: speechmaticsOnly,
                    checkpoint: checkpoint(provider: provider, state: state)) == .deepgram)
            }
        }
    }

    @Test func recordingBeforeSetupCanUseSpeechmaticsWhenConnectedLater() {
        let onlySpeechmatics = CloudFallbackPolicy.Availability(speechmaticsConfigured: true, speechmaticsConsented: true)
        var missingKey = checkpoint(state: .actionRequired)
        missingKey.lastErrorCode = "missing_api_key"
        for saved in [checkpoint(state: .consentBlocked), missingKey] {
            #expect(TranscriptionEngineResolver.resolve(preference: .auto, language: .auto,
                availability: onlySpeechmatics, checkpoint: saved) == .speechmatics)
            #expect(TranscriptionEngineResolver.resolve(preference: .deepgram, language: .auto,
                availability: onlySpeechmatics, checkpoint: saved) == .deepgram)
        }
    }

    @Test func unresolvedUploadsBlockNewSubmissions() {
        let unresolved = [
            checkpoint(state: .ambiguousBilling),
            checkpoint(state: .uploading),
            checkpoint(state: .awaitingResponse),
            checkpoint(provider: .speechmatics, phase: .submitting),
            checkpoint(provider: .speechmatics, phase: .ambiguousSubmission)
        ]
        for saved in unresolved {
            #expect(CloudFallbackPolicy.requiresReview(saved))
            #expect(CloudFallbackPolicy.fallback(
                preference: .auto, failedEngine: .deepgram,
                error: DeepgramError.creditExhausted("Exhausted"), availability: ready,
                checkpoint: saved) == nil)
        }
        #expect(!CloudFallbackPolicy.requiresReview(nil))
        #expect(!CloudFallbackPolicy.requiresReview(checkpoint()))
    }

    @Test func acceptedSpeechmaticsJobResumesEvenAfterEngineOrAvailabilityChanges() {
        let saved = checkpoint(provider: .speechmatics, state: .awaitingResponse,
                               phase: .polling, jobID: "durable-job")
        #expect(!CloudFallbackPolicy.requiresReview(saved))
        for preference in TranscriptionEnginePreference.allCases {
            #expect(TranscriptionEngineResolver.resolve(preference: preference, language: .auto,
                                                        availability: .init(), checkpoint: saved) == .speechmatics)
        }
    }
}
