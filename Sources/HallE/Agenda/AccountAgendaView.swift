import SwiftUI

@MainActor
struct AccountAgendaView: View {
    @State private var model = AccountAgendaModel.shared
    let localEvents: [UnifiedEvent]
    var focusedID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AccountMeeting?
    @State private var deleting: AccountMeeting?
    @State private var choosingOccurrence = false
    @State private var link = false
    @State private var feedback = ""

    private func label(_ en: String, _ es: String) -> String { PublicUICopy.text(en, es) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(label("Private account calendar", "Calendario privado de la cuenta"), systemImage: "calendar.badge.person.crop").font(.title2.bold())
                Spacer()
                Button(label("Close", "Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let account = model.account {
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.origin.host ?? "").font(.headline)
                        Text(label("Account", "Cuenta") + " · " + account.credentials.userId)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button(label("Link a sign-in method", "Vincular otro método")) {
                        link.toggle()
                        model.resetChallenge()
                    }.disabled(model.busy)
                    Button(label("Sign out", "Cerrar sesión")) {
                        Task { await model.run { try await model.signOut() } }
                    }.disabled(model.busy)
                }
                if link { signInControls(linking: true) }
                HStack {
                    Button(label("New meeting", "Nueva reunión"), systemImage: "plus") { editing = .draft() }
                    Button(label("Copy from local calendar…", "Copiar desde la agenda local…")) { choosingOccurrence = true }
                    Spacer()
                    Button(label("Sync", "Sincronizar"), systemImage: "arrow.clockwise") {
                        Task { await model.run { try await model.synchronize() } }
                    }.disabled(model.busy)
                }.disabled(!model.canEdit)
                if !model.cache.pending.isEmpty {
                    Text(label("Changes on this Mac", "Cambios en este Mac") + ": \(model.cache.pending.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.cache.pending.filter(\.conflict)) { change in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(label("This meeting changed on another device.", "Esta reunión cambió en otro dispositivo.")).bold()
                                    Text(change.meeting.title + " · " + change.meeting.startAt + " — " + change.meeting.endAt).textSelection(.enabled)
                                    if model.cache.meetings.contains(where: { $0.id == change.meeting.id && !$0.deleted }) {
                                        Button(label("Apply my change to the current version", "Aplicar mi cambio a la versión actual")) {
                                            local { try model.reapply(change); refresh() }
                                        }
                                    }
                                    Button(label("Keep the server version", "Conservar la versión del servidor")) {
                                        local { try model.keepServerVersion(change) }
                                    }
                                }.padding(8)
                            }
                            if model.cache.visible.isEmpty {
                                Text(label("No meetings in this account calendar.", "No hay reuniones en el calendario de esta cuenta."))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.cache.visible) { meeting in
                                meetingRow(meeting).id(meeting.id)
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { if let focusedID { reader.scrollTo(focusedID, anchor: .top) } }
                }
            } else {
                Text(label("Connect your Hall-e account to share this calendar and its transcripts across your devices.",
                           "Conecta tu cuenta de Hall-e para compartir este calendario y sus transcripciones entre tus dispositivos."))
                TextField(label("HTTPS address of your Hall-e account service", "Dirección HTTPS de tu servicio de cuentas Hall-e"), text: $model.endpoint)
                    .disabled(model.busy || model.challenge != nil || model.waitingForBrowser)
                signInControls(linking: false)
                Spacer()
            }
            if model.busy { ProgressView().controlSize(.small) }
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled) }
            if !feedback.isEmpty { Text(feedback).font(.callout).foregroundStyle(.red) }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 500)
        .task { await model.run { try await model.synchronize() } }
        .onDisappear { model.resetChallenge() }
        .onChange(of: model.account) { _, new in
            editing = nil
            deleting = nil
            choosingOccurrence = false
            link = false
            feedback = ""
            if new == nil { model.resetChallenge() }
        }
        .sheet(item: $editing) { meeting in
            AccountMeetingEditor(meeting: meeting) { updated in
                try model.enqueue(updated)
                refresh()
            }
        }
        .sheet(isPresented: $choosingOccurrence) {
            VStack(alignment: .leading, spacing: 12) {
                Text(label("Copy a timed occurrence", "Copiar una reunión con hora")).font(.headline)
                Text(label("The selected title and times will be sent to this account. The original remains in its source calendar.",
                           "Se enviarán a esta cuenta el título y las horas que elijas. El original seguirá en su calendario de origen."))
                List(localEvents.filter { !$0.isAllDay && $0.status != "cancelled" }) { event in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(event.title)
                            Text(event.startTs.formatted() + " — " + event.endTs.formatted()).font(.caption)
                        }
                        Spacer()
                        Button(label("Copy to my account", "Copiar a mi cuenta")) {
                            local {
                                try model.importOccurrence(event)
                                choosingOccurrence = false
                                refresh()
                            }
                        }
                    }
                }
                Button(label("Close", "Cerrar")) { choosingOccurrence = false }
            }.padding().frame(minWidth: 520, minHeight: 330)
        }
        .alert(label("Delete this account meeting?", "¿Eliminar esta reunión de la cuenta?"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { meeting in
            Button(label("Delete from account", "Eliminar de la cuenta"), role: .destructive) {
                var copy = meeting
                copy.deleted = true
                local { try model.enqueue(copy); refresh() }
            }
            Button(label("Cancel", "Cancelar"), role: .cancel) { }
        } message: { meeting in Text(meeting.title) }
    }

    private func signInControls(linking: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.waitingForBrowser {
                HStack {
                    SecureField(label("8-digit code from browser", "Código de 8 dígitos del navegador"), text: $model.confirmationCode)
                    Button(label("Confirm Google account", "Confirmar cuenta de Google")) {
                        Task { await model.run { try await model.finishGoogle() } }
                    }.disabled(model.confirmationCode.count != 8)
                    Button(label("Cancel", "Cancelar")) { model.resetChallenge() }
                }.disabled(model.busy)
            } else if model.challenge == nil {
                HStack {
                    TextField(label("Email address", "Correo electrónico"), text: $model.email)
                    Button(linking ? label("Link email", "Vincular correo") : label("Send code", "Enviar código")) {
                        Task { await model.run { try await model.startEmail() } }
                    }.disabled(model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(linking ? label("Link Google", "Vincular Google") : label("Continue with Google", "Continuar con Google")) {
                        Task { await model.run { try await model.google() } }
                    }
                }.disabled(model.busy)
            } else {
                HStack {
                    SecureField(label("Email code", "Código del correo"), text: $model.code)
                    Button(linking ? label("Confirm link", "Confirmar vínculo") : label("Sign in", "Iniciar sesión")) {
                        Task { await model.run { try await model.finishEmail() } }
                    }
                    Button(label("Cancel", "Cancelar")) { model.resetChallenge() }
                }.disabled(model.busy)
            }
        }
    }

    private func meetingRow(_ meeting: AccountMeeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(meeting.title).font(.headline)
                Spacer()
                HStack {
                    Button(label("Edit", "Editar")) { editing = meeting }
                    Button(label("Delete", "Eliminar")) { deleting = meeting }
                }.disabled(model.cache.pending.contains { $0.meeting.id == meeting.id })
            }
            if let start = AccountMeeting.date(meeting.startAt), let end = AccountMeeting.date(meeting.endAt) {
                Text(start.formatted() + " — " + end.formatted()).font(.caption).foregroundStyle(.secondary)
            }
            if meeting.revision > 0 && !model.cache.pending.contains(where: { $0.meeting.id == meeting.id }) {
                AccountTranscriptImportControls(meeting: meeting, model: model)
            }
            ForEach(meeting.recordings.filter { $0.source != "local-import" }) { recording in
                VStack(alignment: .leading, spacing: 4) {
                    Label(label("Recording", "Grabación") + " · " + recording.status, systemImage: "waveform")
                        .font(.callout)
                    if let transcript = recording.transcript, !transcript.isEmpty {
                        DisclosureGroup(label("Transcript", "Transcripción")) { Text(transcript).textSelection(.enabled) }
                    }
                }
            }
        }
    }

    private func local(_ operation: () throws -> Void) {
        do { try operation(); feedback = "" } catch { feedback = error.localizedDescription }
    }

    private func refresh() { Task { await model.run { try await model.synchronize() } } }
}

private struct AccountMeetingEditor: View {
    @Environment(\.dismiss) private var dismiss
    let meeting: AccountMeeting
    let save: (AccountMeeting) throws -> Void
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var error = ""

    init(meeting: AccountMeeting, save: @escaping (AccountMeeting) throws -> Void) {
        self.meeting = meeting
        self.save = save
        _title = .init(initialValue: meeting.title)
        _start = .init(initialValue: AccountMeeting.date(meeting.startAt) ?? .now)
        _end = .init(initialValue: AccountMeeting.date(meeting.endAt) ?? .now)
    }

    var body: some View {
        Form {
            TextField(PublicUICopy.text("Meeting title", "Título de la reunión"), text: $title)
            DatePicker(PublicUICopy.text("Starts", "Inicio"), selection: $start)
            DatePicker(PublicUICopy.text("Ends", "Fin"), selection: $end)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button(PublicUICopy.text("Cancel", "Cancelar")) { dismiss() }
                Button(PublicUICopy.text("Save in my account", "Guardar en mi cuenta")) {
                    var next = meeting
                    next.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    next.startAt = AccountMeeting.timestamp(start)
                    next.endAt = AccountMeeting.timestamp(end)
                    do { try save(next); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
        }.padding(20).frame(minWidth: 380)
    }
}
