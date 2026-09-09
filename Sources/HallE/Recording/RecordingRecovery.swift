import Foundation
import AVFoundation

enum RecordingRecovery {
    /// Only interrupted capture is changed. Completed audio and paid provider
    /// jobs retain their existing recovery rules and are never uploaded here.
    static func interrupted(_ original: RecordingSession, audioDuration: TimeInterval?, now: Date) -> RecordingSession? {
        guard original.endedAt == nil else { return nil }
        switch original.state {
        case .preparing, .recording, .stopping: break
        default: return nil
        }
        var session = original
        let message = "Recording was interrupted. Original audio is preserved; review playback before retrying transcription."
        session.endedAt = audioDuration.map { (session.micStartedAt ?? session.startedAt).addingTimeInterval($0) } ?? now
        session.state = .failed(message)
        session.stopReason = .recorderFailed
        session.transcriptStatus = .failed
        var job = session.transcriptionJob ?? TranscriptionJob()
        job.status = .retryableFailed
        job.lastError = message
        session.transcriptionJob = job
        return session
    }

    static func reconcileInterruptedCaptures() {
        for session in RecordingStore.allSessions() {
            let duration: TimeInterval?
            if let file = try? AVAudioFile(forReading: session.micURL), file.fileFormat.sampleRate > 0 {
                duration = Double(file.length) / file.fileFormat.sampleRate
            } else { duration = nil }
            if let recovered = interrupted(session, audioDuration: duration, now: Date()) { recovered.save() }
        }
    }
}
