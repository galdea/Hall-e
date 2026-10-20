import Testing
import Foundation
@testable import HallE

@Suite("Meeting dropdown transcription")
struct MeetingTranscriptionActionTests {
    private func action(_ job: TranscriptionJob, audio: Bool = true,
                        finished: Bool = true, processing: Bool = false) -> MeetingTranscriptionAction {
        .evaluate(isFinished: finished, hasAudio: audio, job: job, isProcessing: processing)
    }

    @Test func noRecordingOrMissingAudioCannotQueueWork() {
        #expect(MeetingTranscriptionAction.forSession(nil, isProcessing: false) == .unavailable(.noAudio))
        #expect(action(.init(), audio: false) == .unavailable(.noAudio))
        #expect(action(.init(status: .completed), audio: false) == .unavailable(.noAudio))
    }

    @Test func captureAndInFlightWorkCannotStartASecondJob() {
        #expect(action(.init(), finished: false) == .unavailable(.recording))
        #expect(action(.init(), processing: true) == .unavailable(.processing))
        #expect(action(.init(status: .running)) == .unavailable(.processing))
        #expect(action(.init(status: .completed), processing: true) == .unavailable(.processing))
    }

    @Test(arguments: [TranscriptionJobStatus.queued, .retryableFailed, .actionRequired, .consentBlocked, .cancelled])
    func pendingAndRecoverableStatesUseTheExistingQueue(status: TranscriptionJobStatus) {
        #expect(action(.init(status: status)) == .transcribe)
    }

    @Test func completedTranscriptRequiresConfirmationAndFreshState() {
        let id = UUID()
        var gate = MeetingTranscriptionRequestGate()
        #expect(action(.init(status: .completed)) == .retranscribe)
        let unconfirmed = gate.begin(id, action: .retranscribe, confirmedRetranscription: false)
        #expect(!unconfirmed)
        #expect(!gate.contains(id))
        let confirmed = gate.begin(id, action: .retranscribe, confirmedRetranscription: true)
        let repeated = gate.begin(id, action: .retranscribe, confirmedRetranscription: true)
        #expect(confirmed)
        #expect(!repeated)
        gate.finish(id)
        // A stale completed-row confirmation must not reset newer running work.
        let stale = gate.begin(id, action: action(.init(status: .running)), confirmedRetranscription: true)
        #expect(!stale)
    }

    @Test func ambiguousUploadIsBlockedEvenWithRetranscriptionConfirmation() {
        let cloud = CloudTranscriptionJob(
            state: .ambiguousBilling, requestFingerprint: "synthetic-uncertain", estimatedCostUSD: 0,
            requestID: nil, retryAfter: nil, lastHTTPStatus: nil, lastErrorCode: nil,
            updatedAt: Date(), provider: .speechmatics, phase: .ambiguousSubmission, providerJobID: nil)
        for status in [TranscriptionJobStatus.ambiguousBilling, .retryableFailed, .completed] {
            let policy = action(.init(status: status, cloud: cloud))
            #expect(policy == .unavailable(.providerReview))
            var gate = MeetingTranscriptionRequestGate()
            let requested = gate.begin(UUID(), action: policy, confirmedRetranscription: true)
            #expect(!requested)
        }
        #expect(action(.init(status: .ambiguousBilling)) == .unavailable(.providerReview))
    }

    @Test func acceptedRemoteJobRetriesPreserveProviderIDRegionAndBackoff() {
        let deadline = Date().addingTimeInterval(120)
        var job = TranscriptionJob(status: .retryableFailed, cloud: .init(
            state: .retryableFailure, requestFingerprint: "synthetic-accepted", estimatedCostUSD: 0,
            requestID: "synthetic-job", retryAfter: deadline, lastHTTPStatus: 429,
            lastErrorCode: nil, updatedAt: Date(), provider: .speechmatics,
            phase: .polling, providerJobID: "synthetic-job", providerRegion: "us1"))
        #expect(action(job) == .transcribe)
        job.queueForRetry()
        #expect(job.cloud?.providerJobID == "synthetic-job")
        #expect(job.cloud?.providerRegion == "us1")
        #expect(job.cloud?.retryAfter == deadline)
        #expect(!job.isDueForAutomaticRetry())
    }

    @Test func repeatedClicksAcrossControlsClaimOnlyOneHandoff() {
        let id = UUID(), other = UUID()
        var gate = MeetingTranscriptionRequestGate()
        var dispatches = 0
        for _ in 0..<10 {
            if gate.begin(id, action: .transcribe, confirmedRetranscription: false) { dispatches += 1 }
        }
        #expect(dispatches == 1)
        let independent = gate.begin(other, action: .transcribe, confirmedRetranscription: false)
        #expect(independent)
        gate.finish(id)
        #expect(!gate.contains(id))
        #expect(gate.contains(other))
        // After handoff the worker's persisted running state keeps clicks inert.
        let running = gate.begin(id, action: action(.init(status: .running)), confirmedRetranscription: false)
        #expect(!running)
        // A later genuine recoverable failure can be requested again.
        let laterRetry = gate.begin(id, action: action(.init(status: .retryableFailed)), confirmedRetranscription: false)
        #expect(laterRetry)
    }
}
