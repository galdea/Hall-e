import Foundation

/// Shared by the meeting controls and command boundary. A visible stale row
/// must not reset a queued job or turn an uncertain upload into a new request.
enum MeetingTranscriptionAction: Equatable {
    enum Block: Equatable {
        case noAudio, recording, processing, providerReview
    }
    case transcribe
    case retranscribe
    case unavailable(Block)

    var isEnabled: Bool {
        if case .unavailable = self { return false }
        return true
    }

    static func evaluate(isFinished: Bool, hasAudio: Bool,
                         job: TranscriptionJob, isProcessing: Bool) -> Self {
        guard isFinished else { return .unavailable(.recording) }
        guard hasAudio else { return .unavailable(.noAudio) }
        guard !isProcessing, job.status != .running else { return .unavailable(.processing) }
        guard job.status != .ambiguousBilling,
              !CloudFallbackPolicy.requiresReview(job.cloud) else { return .unavailable(.providerReview) }
        return job.status == .completed ? .retranscribe : .transcribe
    }

    static func forSession(_ session: RecordingSession?, isProcessing: Bool) -> Self {
        guard let session else { return .unavailable(.noAudio) }
        return evaluate(isFinished: session.isFinished, hasAudio: session.hasPlayableAudio,
                        job: session.transcriptionJob ?? .legacy(status: session.transcriptStatus),
                        isProcessing: isProcessing || session.transcriptStatus == .inProgress)
    }

    var title: String {
        switch self {
        case .retranscribe: PublicUICopy.text("Re-transcribe", "Volver a transcribir")
        case .unavailable(.processing): PublicUICopy.text("Transcribing…", "Transcribiendo…")
        default: PublicUICopy.text("Transcribe", "Transcribir")
        }
    }

    var help: String {
        switch self {
        case .transcribe:
            PublicUICopy.text("Transcribe the saved recording using your current settings.",
                              "Transcribir la grabación guardada con tu configuración actual.")
        case .retranscribe:
            PublicUICopy.text("Confirm before generating a new transcript. The current transcript is kept until its replacement is ready.",
                              "Confirma antes de generar otra transcripción. La actual se conserva hasta que la nueva esté lista.")
        case .unavailable(.noAudio):
            PublicUICopy.text("No saved audio is available for this meeting.",
                              "No hay audio guardado disponible para esta reunión.")
        case .unavailable(.recording):
            PublicUICopy.text("Finish the recording before transcribing it.",
                              "Termina la grabación antes de transcribirla.")
        case .unavailable(.processing):
            PublicUICopy.text("This recording is already queued or being transcribed.",
                              "Esta grabación ya está en cola o se está transcribiendo.")
        case .unavailable(.providerReview):
            PublicUICopy.text("Review the uncertain provider submission in Transcript before retrying.",
                              "Revisa el envío pendiente de confirmar en Transcripción antes de reintentarlo.")
        }
    }
}

/// Claims synchronously, before a worker Task starts, so two menu/toolbar clicks
/// cannot reset or queue the same recording during the async handoff.
struct MeetingTranscriptionRequestGate {
    private var requests = Set<UUID>()

    func contains(_ sessionID: UUID) -> Bool { requests.contains(sessionID) }

    mutating func begin(_ sessionID: UUID, action: MeetingTranscriptionAction,
                        confirmedRetranscription: Bool) -> Bool {
        guard action.isEnabled,
              action != .retranscribe || confirmedRetranscription else { return false }
        return requests.insert(sessionID).inserted
    }

    mutating func finish(_ sessionID: UUID) { requests.remove(sessionID) }
}
