import AppKit
import SwiftUI

struct MeetingNotesView: View {
    let session: RecordingSession
    @State private var notes = ""
    @State private var loadedSessionID: UUID?
    @State private var error: String?
    @State private var saved = false
    private let store = MeetingNotesStore()
    private func copy(_ en: String, _ es: String) -> String { PublicUICopy.text(en, es) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(copy("My notes", "Mis notas"), systemImage: "square.and.pencil").font(.headline)
                Spacer()
                Button(copy("Export meeting", "Exportar reunión")) { export() }
                    .disabled(loadedSessionID != session.id)
            }
            Text(copy("Keep decisions, questions, and next steps here. Your writing is saved automatically.", "Anota decisiones, preguntas y próximos pasos. Lo que escribas se guarda automáticamente."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.body).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 130, maxHeight: 230)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
                .accessibilityLabel(copy("Meeting notes", "Notas de la reunión"))
                .disabled(loadedSessionID != session.id)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                Button(copy("Try saving again", "Reintentar guardado")) {
                    if loadedSessionID == session.id { save() } else { load() }
                }
            } else {
                HStack {
                    Label(saved ? copy("All changes saved on this Mac", "Todos los cambios guardados en este Mac") : copy("Private notes · no account needed", "Notas privadas · sin cuenta"),
                          systemImage: saved ? "checkmark" : "lock")
                    Spacer()
                    Button(copy("Show notes folder", "Ver carpeta de notas")) {
                        NSWorkspace.shared.activateFileViewerSelecting([store.url(for: session.id)])
                    }.buttonStyle(.link).disabled(!saved)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: session.id) { load() }
        .onChange(of: notes) { _, _ in
            guard loadedSessionID == session.id else { return }
            save()
        }
    }

    private func load() {
        loadedSessionID = nil
        do {
            notes = try store.load(sessionID: session.id)
            saved = FileManager.default.fileExists(atPath: store.url(for: session.id).path)
            error = nil
            loadedSessionID = session.id
        } catch {
            self.error = copy("The notes could not be opened. \(error.localizedDescription)", "No se pudieron abrir las notas. \(error.localizedDescription)")
        }
    }

    private func save() {
        do { try store.save(notes, sessionID: session.id); saved = true; error = nil }
        catch {
            saved = false
            self.error = copy("Changes are not saved. \(error.localizedDescription)", "Los cambios no están guardados. \(error.localizedDescription)")
        }
    }

    private func export() {
        let markdown = MeetingNotesStore.export(title: session.eventTitle, date: session.startedAt,
            notes: notes, transcript: TranscriptStore.load(session)?.speakerLabeledText ?? "")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FilenameSanitizer.sanitize(session.eventTitle, maxBytes: 100) + ".md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(markdown.utf8).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }
}
