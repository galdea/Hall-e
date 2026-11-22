import SwiftUI

@MainActor
struct AccountAgendaView: View {
    @State private var model = AccountAgendaModel.shared
    let localEvents: [UnifiedEvent]
    let localDecisions: LocalProjectDecisions
    let localProjects: [Project]
    let localRecordings: [String: RecordingSession]
    var focusedID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var editing: AccountMeeting?
    @State private var deleting: AccountMeeting?
    @State private var choosingOccurrence = false
    @State private var link = false
    @State private var feedback = ""
    @State private var discarding: RecordingDiscard?

    private struct RecordingDiscard {
        var meetingId: String
        var meetingTitle: String
        var recording: AccountRecording
        var account: AccountConnection
    }

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
                    if !model.usesStagingMailbox {
                        Button(label("Link a sign-in method", "Vincular otro método")) {
                            link.toggle()
                            model.resetChallenge()
                        }.disabled(model.busy)
                    }
                    Button(label("Sign out", "Cerrar sesión")) {
                        Task { await model.run { try await model.signOut() } }
                    }.disabled(model.busy)
                }
                if link { signInControls(linking: true) }
                HStack {
                    Button(label("New meeting", "Nueva reunión"), systemImage: "plus") { editing = .draft() }
                    Button(label("Copy a local meeting…", "Copiar una reunión local…")) { choosingOccurrence = true }
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
                                conflictBanner(change, model.conflict(for: change))
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
            discarding = nil
            choosingOccurrence = false
            link = false
            feedback = ""
            if new == nil { model.resetChallenge() }
        }
        .sheet(item: $editing) { meeting in
            AccountMeetingEditor(meeting: meeting, projects: model.cache.visible.compactMap(\.project)) { updated in
                try model.enqueue(updated)
                refresh()
            }
        }
        .sheet(isPresented: $choosingOccurrence) { localCalendarPicker }
        .alert(label("Delete this account meeting?", "¿Eliminar esta reunión de la cuenta?"),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { meeting in
            Button(label("Delete from account", "Eliminar de la cuenta"), role: .destructive) {
                var copy = meeting
                copy.deleted = true
                local { try model.enqueue(copy); refresh() }
            }
            Button(label("Cancel", "Cancelar"), role: .cancel) { }
        } message: { meeting in Text(meeting.title) }
        .confirmationDialog(label("Discard this recording?", "¿Descartar esta grabación?"),
                            isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                            titleVisibility: .visible, presenting: discarding) { proposed in
            Button(label("Discard recording", "Descartar grabación"), role: .destructive) {
                Task {
                    await model.run {
                        try await model.discardRecording(meetingId: proposed.meetingId, recording: proposed.recording,
                                                         from: proposed.account)
                    }
                }
            }
            Button(label("Cancel", "Cancelar"), role: .cancel) { }
        } message: { proposed in
            Text(label("The account service will delete this recording’s audio and any partial transcript from “\(proposed.meetingTitle)” on all your devices. The meeting itself stays.",
                       "El servicio de cuentas eliminará el audio y cualquier transcripción parcial de esta grabación de «\(proposed.meetingTitle)» en todos tus dispositivos. La reunión se conserva."))
        }
    }

    private var localCalendarPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label("Copy a timed occurrence", "Copiar una reunión con hora")).font(.headline)
            Text(label("Copy a meeting’s title and times. If you confirmed a local project, you can also choose to share its name with this account.",
                       "Copia el título y el horario de una reunión. Si confirmaste un proyecto local, también puedes elegir compartir su nombre con esta cuenta."))
            let existing = model.cache.visible.compactMap(\.project)
            let historical = AccountMeeting.recordedOccurrences(outside: localEvents, recordings: localRecordings)
            List {
                Section(label("Local calendar", "Agenda local")) {
                    ForEach(localEvents.filter { !$0.isAllDay && $0.status != "cancelled" }) { event in
                        localMeetingRow(event, existing: existing)
                    }
                }
                if !historical.isEmpty {
                    Section(label("Previously recorded meetings", "Reuniones grabadas anteriormente")) {
                        ForEach(historical) { event in localMeetingRow(event, existing: existing) }
                    }
                }
            }
            if !feedback.isEmpty { Text(feedback).foregroundStyle(.red) }
            Button(label("Close", "Cerrar")) { choosingOccurrence = false }
        }.padding().frame(minWidth: 520, minHeight: 330)
    }

    private func localMeetingRow(_ event: UnifiedEvent, existing: [AccountProject]) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(event.title)
                Text(event.startTs.formatted() + " — " + event.endTs.formatted()).font(.caption)
            }
            Spacer()
            if let account = model.account {
                if let project = AccountProject.confirmedCopy(for: event, decisions: localDecisions, projects: localProjects,
                                                             account: account, existing: existing) {
                    Menu(label("Copy to my account", "Copiar a mi cuenta")) {
                        Button(label("Copy title and times only", "Copiar solo título y horario")) {
                            copyOccurrence(event, project: nil, into: account)
                        }
                        Button(label("Include project “\(project.name)”", "Incluir el proyecto «\(project.name)»")) {
                            copyOccurrence(event, project: project, into: account)
                        }
                    }.fixedSize()
                } else {
                    Button(label("Copy to my account", "Copiar a mi cuenta")) {
                        copyOccurrence(event, project: nil, into: account)
                    }
                }
            }
        }
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
                    if !model.usesStagingMailbox {
                        Button(linking ? label("Link Google", "Vincular Google") : label("Continue with Google", "Continuar con Google")) {
                            Task { await model.run { try await model.google() } }
                        }
                    }
                }.disabled(model.busy)
                if model.usesStagingMailbox {
                    Text(label("Request one code per device. Open Hall-e Staging Code.command on the Mac to read it.",
                               "Solicita un código por dispositivo. Abre Hall-e Staging Code.command en el Mac para verlo."))
                        .font(.callout)
                }
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
        .onChange(of: model.usesStagingMailbox, initial: true) { _, staging in
            let tester = "halle-owner@example.test"
            if staging && !linking && model.email.isEmpty { model.email = tester }
            else if !staging && AppPaths.isStaging && model.email == tester { model.email = "" }
        }
    }

    private func conflictBanner(_ change: AgendaMutation, _ conflict: AgendaConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch conflict.server {
            case .live:
                Text(label("This meeting changed on another device.", "Esta reunión cambió en otro dispositivo.")).bold()
            case .deleted:
                Text(label("Another device deleted this meeting.", "Otro dispositivo eliminó esta reunión.")).bold()
            case .missing:
                Text(label("The account service did not accept this change.", "El servicio de cuentas no aceptó este cambio.")).bold()
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label("On the server", "En el servidor")).font(.caption.bold()).foregroundStyle(.secondary)
                    switch conflict.server {
                    case .live(let server): conflictDetails(server)
                    case .deleted: Text(label("Deleted", "Eliminada")).italic()
                    case .missing: Text(label("Not saved on the server", "No está guardada en el servidor")).italic()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label("Your change on this Mac", "Tu cambio en este Mac")).font(.caption.bold()).foregroundStyle(.secondary)
                    if conflict.localDeletes {
                        Text(label("Delete this meeting", "Eliminar esta reunión")).italic()
                        Text(conflict.local.title).font(.caption).foregroundStyle(.secondary)
                    } else {
                        conflictDetails(conflict.local)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if conflict.canReapply {
                    Button(label("Apply my change to the current version", "Aplicar mi cambio a la versión actual")) {
                        local { try model.reapply(change); refresh() }
                    }
                }
                if conflict.canSaveAsNew {
                    Button(label("Save my version as a new meeting", "Guardar mi versión como una reunión nueva")) {
                        local { try model.saveAsNewMeeting(change); refresh() }
                    }
                }
                Button(conflict.server == .missing ? label("Discard my change", "Descartar mi cambio")
                                                   : label("Keep the server version", "Conservar la versión del servidor")) {
                    local { try model.keepServerVersion(change) }
                }
            }
        }
        .padding(8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private func conflictDetails(_ meeting: AccountMeeting) -> some View {
        Text(meeting.title).textSelection(.enabled)
        if let start = AccountMeeting.date(meeting.startAt), let end = AccountMeeting.date(meeting.endAt) {
            Text(start.formatted() + " — " + end.formatted()).font(.caption)
        } else {
            Text(meeting.startAt + " — " + meeting.endAt).font(.caption)
        }
        Text(meeting.project?.name ?? label("No project", "Sin proyecto")).font(.caption).foregroundStyle(.secondary)
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
            if let project = meeting.project { Label(project.name, systemImage: "folder").font(.callout) }
            if meeting.revision > 0 && !model.cache.pending.contains(where: { $0.meeting.id == meeting.id }) {
                AccountTranscriptImportControls(meeting: meeting, model: model)
            }
            ForEach(meeting.recordings.filter { $0.source != "local-import" }) { recording in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(label("Recording", "Grabación") + " · " + recording.status, systemImage: "waveform")
                            .font(.callout)
                        if recording.canDiscard, let account = model.account {
                            Button(label("Discard recording…", "Descartar grabación…"), role: .destructive) {
                                discarding = RecordingDiscard(meetingId: meeting.id, meetingTitle: meeting.title,
                                                              recording: recording, account: account)
                            }
                            .disabled(model.busy || model.cache.pending.contains { $0.meeting.id == meeting.id })
                        }
                    }
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

    private func copyOccurrence(_ event: UnifiedEvent, project: AccountProject?, into account: AccountConnection) {
        local {
            try model.importOccurrence(event, project: project, into: account)
            choosingOccurrence = false
            refresh()
        }
    }

    private func refresh() { Task { await model.run { try await model.synchronize() } } }
}

private struct AccountMeetingEditor: View {
    @Environment(\.dismiss) private var dismiss
    let meeting: AccountMeeting
    let projects: [AccountProject]
    let save: (AccountMeeting) throws -> Void
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var error = ""
    @State private var projectID: String
    @State private var newName = ""

    init(meeting: AccountMeeting, projects: [AccountProject], save: @escaping (AccountMeeting) throws -> Void) {
        self.meeting = meeting
        self.save = save
        self.projects = Dictionary(grouping: projects, by: \.id).compactMap { $0.value.first }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        _projectID = .init(initialValue: meeting.project?.id ?? "")
        _title = .init(initialValue: meeting.title)
        _start = .init(initialValue: AccountMeeting.date(meeting.startAt) ?? .now)
        _end = .init(initialValue: AccountMeeting.date(meeting.endAt) ?? .now)
    }

    var body: some View {
        Form {
            TextField(PublicUICopy.text("Meeting title", "Título de la reunión"), text: $title)
            DatePicker(PublicUICopy.text("Starts", "Inicio"), selection: $start)
            DatePicker(PublicUICopy.text("Ends", "Fin"), selection: $end)
            Picker(PublicUICopy.text("Private account project", "Proyecto privado de la cuenta"), selection: $projectID) {
                Text(PublicUICopy.text("Unassigned", "Sin proyecto")).tag("")
                ForEach(projects) { Text($0.name).tag($0.id) }
                Text(PublicUICopy.text("New project…", "Nuevo proyecto…")).tag("new")
            }
            if projectID == "new" {
                TextField(PublicUICopy.text("Project name shared with this account", "Nombre que se compartirá con esta cuenta"), text: $newName)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button(PublicUICopy.text("Cancel", "Cancelar")) { dismiss() }
                Button(PublicUICopy.text("Save in my account", "Guardar en mi cuenta")) {
                    var next = meeting
                    next.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    next.startAt = AccountMeeting.timestamp(start)
                    next.endAt = AccountMeeting.timestamp(end)
                    if projectID == "new" {
                        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, name.utf16.count <= 120, name.rangeOfCharacter(from: .controlCharacters) == nil else {
                            error = PublicUICopy.text("Enter a project name of up to 120 characters.", "Escribe un nombre de proyecto de hasta 120 caracteres.")
                            return
                        }
                        next.project = projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                            ?? AccountProject(id: UUID().uuidString.lowercased(), name: name)
                    } else { next.project = projects.first { $0.id == projectID } }
                    do { try save(next); dismiss() } catch { self.error = error.localizedDescription }
                }
            }
        }.padding(20).frame(minWidth: 380)
    }
}
