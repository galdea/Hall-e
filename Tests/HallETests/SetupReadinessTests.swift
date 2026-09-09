import Testing
@testable import HallE

@Suite struct SetupReadinessTests {
    @Test func freshInstallNeedsNoCloudAccount() {
        let readiness = SetupReadiness(microphoneGranted: true, speechGranted: true,
                                       localModelAvailable: true, engine: .auto, cloud: .init())
        #expect(readiness.usesLocalTranscription)
        #expect(readiness.readyToMeet)
    }
    @Test func permissionAloneDoesNotGuaranteeLocalModel() {
        let readiness = SetupReadiness(microphoneGranted: true, speechGranted: true,
                                       localModelAvailable: false, engine: .auto, cloud: .init())
        #expect(!readiness.transcriptionReady)
        #expect(!readiness.readyToMeet)
    }
    @Test func explicitCloudChoiceIsPreserved() {
        let readiness = SetupReadiness(microphoneGranted: true, speechGranted: true,
                                       localModelAvailable: true, engine: .deepgram, cloud: .init())
        #expect(!readiness.usesLocalTranscription)
        #expect(!readiness.transcriptionReady)
    }
    @Test func cloudKeyWithoutConsentIsNotReady() {
        let readiness = SetupReadiness(microphoneGranted: true, speechGranted: false,
                                       localModelAvailable: true, engine: .auto,
                                       cloud: .init(deepgramConfigured: true, deepgramConsented: false))
        #expect(!readiness.transcriptionReady)
    }
    @Test func cloudUsersDoNotNeedSpeechPermission() {
        let readiness = SetupReadiness(microphoneGranted: true, speechGranted: false,
                                       localModelAvailable: false, engine: .auto,
                                       cloud: .init(deepgramConfigured: true, deepgramConsented: true))
        #expect(readiness.readyToMeet)
        #expect(!readiness.usesLocalTranscription)
    }
    @Test func completionStillRequiresMicrophone() {
        let readiness = SetupReadiness(microphoneGranted: false, speechGranted: true,
                                       localModelAvailable: true, engine: .sfSpeech, cloud: .init())
        #expect(readiness.transcriptionReady)
        #expect(!readiness.readyToMeet)
    }
    @Test func resumedStepsAreClamped() {
        #expect(SetupReadiness.restoredStep(-2) == 0)
        #expect(SetupReadiness.restoredStep(2) == 2)
        #expect(SetupReadiness.restoredStep(99) == 3)
    }
}
