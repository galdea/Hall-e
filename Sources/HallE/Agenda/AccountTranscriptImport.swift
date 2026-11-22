import SwiftUI

enum TranscriptImportFailure: LocalizedError, Equatable {
    case unavailable, tooLarge
    var errorDescription: String? {
        switch self {
        case .unavailable:
            PublicUICopy.text("This completed transcript is unavailable.", "Esta transcripción completada no está disponible.")
        case .tooLarge:
            PublicUICopy.text("This transcript exceeds the 512 KiB import limit.", "Esta transcripción supera el límite de 512 KiB.")
        }
    }
}

/// Client-side rules for copying a Mac transcript into the account. They mirror the account
/// service's limits so an oversize or empty copy is refused before anything is sent.
enum AccountTranscriptImportPolicy {
    static let maxBytes = 512 * 1024

    /// Returns the text to upload, or throws when it is empty or over the limit.
    static func copy(plainText: String, speakerLabeledText: String) throws -> String {
        guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !speakerLabeledText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TranscriptImportFailure.unavailable }
        guard speakerLabeledText.utf8.count <= maxBytes else { throw TranscriptImportFailure.tooLarge }
        return speakerLabeledText
    }

    /// User-facing text for the import responses the sheet handles itself; nil for anything else.
    static func message(for error: Error) -> String? {
        switch error {
        case AccountAgendaError.response(410, "import_removed"):
            PublicUICopy.text("This account copy was removed.", "Esta copia se eliminó de la cuenta.")
        case AccountAgendaError.response(409, "import_conflict"):
            PublicUICopy.text("A copy of this transcript is already saved in the account.",
                              "Ya existe una copia de esta transcripción en la cuenta.")
        default: nil
        }
    }
}

struct AccountTranscriptImportControls: View {
    @State private var selection: TranscriptImportSelection?
    @State private var removal: Removal?
    let meeting: AccountMeeting
    let model: AccountAgendaModel

    private struct Removal {
        var recording: AccountRecording
        var account: AccountConnection
    }

    private func text(_ english: String, _ spanish: String) -> String { PublicUICopy.text(english, spanish) }

    var body: some View {
        if meeting.revision > 0, !meeting.deleted, let account = model.account {
            Button(text("Copy Mac transcript…", "Copiar transcripción del Mac…")) {
                selection = TranscriptImportSelection(account: account, meeting: meeting)
            }.disabled(model.busy)
            .sheet(item: $selection) { selected in
                TranscriptImportSheet(selection: selected, model: model)
            }

            ForEach(meeting.recordings.filter { $0.source == "local-import" }) { recording in
                AccountTranscriptDisclosure(title: text("Copied Mac transcript", "Transcripción copiada del Mac"),
                                            meetingId: meeting.id, recording: recording, model: model) {
                    Button(text("Remove account copy…", "Eliminar copia de la cuenta…"), role: .destructive) {
                        removal = Removal(recording: recording, account: account)
                    }.disabled(model.busy)
                }
            }
            .confirmationDialog(text("Remove the copied transcript?", "¿Eliminar la transcripción copiada?"),
                                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                                titleVisibility: .visible, presenting: removal) { proposed in
                Button(text("Remove account copy", "Eliminar copia de la cuenta"), role: .destructive) {
                    Task {
                        await model.run {
                            try await model.removeImportedTranscript(meetingId: meeting.id, importId: proposed.recording.id, from: proposed.account)
                        }
                    }
                }
                .disabled(model.busy)
            } message: { _ in
                Text(text("The original recording and transcript stay on this Mac.",
                          "La grabación y la transcripción originales se conservan en este Mac."))
            }
        }
    }
}

private struct TranscriptImportSelection: Identifiable {
    let id = UUID()
    let account: AccountConnection
    let meeting: AccountMeeting
}

private struct TranscriptImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [RecordingSession] = []
    @State private var selectedId: UUID?
    @State private var draft: Draft?
    @State private var error = ""
    let selection: TranscriptImportSelection
    let model: AccountAgendaModel

    private struct Draft: Identifiable {
        var id: String
        var title: String
        var text: String
    }

    private func text(_ english: String, _ spanish: String) -> String { PublicUICopy.text(english, spanish) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("Copy a completed Mac transcript", "Copiar una transcripción completada del Mac")).font(.headline)
            Text(selection.meeting.title).font(.subheadline)
            if sessions.isEmpty {
                Text(text("There are no completed transcripts in the Mac library.",
                          "No hay transcripciones completadas en la biblioteca del Mac."))
            } else {
                Picker(text("Local recording", "Grabación local"), selection: $selectedId) {
                    Text(text("Select a recording", "Selecciona una grabación")).tag(nil as UUID?)
                    ForEach(sessions) { session in
                        Text("\(session.eventTitle) · \(session.startedAt.formatted())").tag(Optional(session.id))
                    }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.secondary) }
            HStack {
                Button(text("Close", "Cerrar")) { dismiss() }
                Spacer()
                Button(text("Review copy…", "Revisar copia…"), action: prepare)
                    .disabled(selectedId == nil || model.busy || model.account != selection.account)
            }
        }
        .padding(20).frame(width: 480)
        .task {
            sessions = RecordingStore.allSessions().filter { $0.transcriptStatus == .completed }
                .sorted { $0.startedAt > $1.startedAt }
        }
        .alert(text("Copy the transcript to your account?", "¿Copiar la transcripción a tu cuenta?"),
               isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } }),
               presenting: draft) { proposed in
            Button(text("Copy transcript", "Copiar transcripción")) { submit(proposed) }
                .disabled(model.busy)
            Button(text("Cancel", "Cancelar"), role: .cancel) {}
        } message: { proposed in
            Text(text("Copy “\(proposed.title)” to “\(selection.meeting.title)”. Your account devices can read the copy. Audio and notes stay on this Mac.",
                      "Copia «\(proposed.title)» a «\(selection.meeting.title)». Los dispositivos de tu cuenta podrán leer la copia. El audio y las notas se quedan en este Mac."))
        }
    }

    private func prepare() {
        error = ""
        do {
            guard model.account == selection.account,
                  let session = sessions.first(where: { $0.id == selectedId }),
                  let transcript = TranscriptStore.load(session), transcript.status == .completed,
                  transcript.sessionID == session.id
            else { throw TranscriptImportFailure.unavailable }
            let copy = try AccountTranscriptImportPolicy.copy(plainText: transcript.plainText,
                                                              speakerLabeledText: transcript.speakerLabeledText)
            let id = AccountAgendaModel.transcriptImportID(meetingId: selection.meeting.id, sessionId: session.id, account: selection.account)
            draft = Draft(id: id, title: session.eventTitle, text: copy)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit(_ proposed: Draft) {
        Task {
            await model.run {
                do {
                    try await model.importTranscript(meetingId: selection.meeting.id, importId: proposed.id,
                                                     text: proposed.text, into: selection.account)
                    dismiss()
                } catch let failure where AccountTranscriptImportPolicy.message(for: failure) != nil {
                    self.error = AccountTranscriptImportPolicy.message(for: failure) ?? ""
                } catch {
                    self.error = error.localizedDescription
                    throw error
                }
            }
        }
    }
}
