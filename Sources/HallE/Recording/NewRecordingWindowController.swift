import AppKit
import SwiftUI

/// Manual capture works without calendar access or a browser extension.
@MainActor
final class NewRecordingWindowController: NSWindowController {
    static let shared = NewRecordingWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 510),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = PublicUICopy.text("New recording", "Nueva grabación")
        window.contentMinSize = NSSize(width: 560, height: 510)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show() {
        guard !RecordingService.shared.isRecording else { WorkspaceWindowController.shared.show(); return }
        if window?.isVisible != true {
            window?.contentView = NSHostingView(rootView: NewRecordingView { [weak self] in self?.close() })
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct MeetingAudioApp: Identifiable {
    let id: String
    let name: String
}

private struct NewRecordingView: View {
    @State private var title = ""
    @State private var selectedApp = ""
    @State private var apps: [MeetingAudioApp] = []
    @State private var starting = false
    @State private var error: String?
    @State private var recorder = RecordingService.shared
    let onClose: () -> Void

    private func copy(_ en: String, _ es: String) -> String { PublicUICopy.text(en, es) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                recordingOptions
            }
            HStack {
                Text(copy("Saved on this Mac", "Se guarda en este Mac")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copy("Cancel", "Cancelar")) { onClose() }.keyboardShortcut(.cancelAction).disabled(starting)
                Button(starting ? copy("Starting…", "Iniciando…") : copy("Start recording", "Iniciar grabación")) { start() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(starting)
            }
        }.padding(28).frame(minWidth: 560, minHeight: 510)
            .onAppear { refreshApps() }
    }

    private var recordingOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(copy("A place for every conversation", "Un espacio para cada conversación"), systemImage: "waveform")
                .font(.title2.weight(.semibold))
            Text(copy("Name your meeting and choose what to record.", "Ponle nombre a tu reunión y elige qué grabar."))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text(copy("Meeting name", "Nombre de la reunión")).font(.headline)
                TextField(copy("e.g. Weekly team meeting", "Por ejemplo: Reunión semanal"), text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(copy("Audio source", "Fuente de audio")).font(.headline)
                Picker(copy("Record", "Grabar"), selection: $selectedApp) {
                    Text(copy("Microphone only · in person", "Solo micrófono · presencial")).tag("")
                    ForEach(apps) { app in
                        Text(copy("Microphone + \(app.name)", "Micrófono + \(app.name)")).tag(app.id)
                    }
                }.labelsHidden()
                Text(selectedApp.isEmpty
                     ? copy("For online meetings, choose the app where you hear the other participants. Your microphone alone will miss voices playing through headphones.", "Para reuniones en línea, elige la app donde escuchas a los participantes. El micrófono por sí solo no captura las voces que salen por audífonos.")
                     : copy("Join the call first. Hall-e captures audio from this app, including other tabs or windows playing sound. macOS may ask for audio recording permission.", "Entra primero a la llamada. Hall-e captura el audio de esta app, incluidas otras pestañas o ventanas que reproduzcan sonido. macOS puede pedir permiso para grabar audio."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(copy("Refresh open apps", "Actualizar apps abiertas")) { refreshApps() }
                    .buttonStyle(.link)
            }
            Label(copy("Tell everyone before recording.", "Avisa a todos antes de grabar."), systemImage: "person.2")
                .font(.callout)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                if recorder.micAuthorization == .denied {
                    Button(copy("Open microphone settings", "Abrir ajustes del micrófono")) { SystemSettingsOpener.openMicrophonePrivacy() }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshApps() {
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != AppPaths.bundleID, seen.insert(id).inserted else { return nil }
            return MeetingAudioApp(id: id, name: app.localizedName ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !apps.contains(where: { $0.id == selectedApp }) { selectedApp = "" }
    }

    private func start() {
        starting = true; error = nil
        let now = Date()
        let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = UnifiedEvent(dedupKey: "manual:\(UUID().uuidString)",
            title: enteredTitle.isEmpty ? copy("Recording — \(HalleDate.time(now))", "Grabación — \(HalleDate.time(now))") : String(enteredTitle.prefix(180)),
            startTs: now, endTs: now, isAllDay: false, status: "confirmed",
            winnerAccountEmail: AppPreferences.primaryAccountEmail ?? "", sourcesJSON: "[]")
        let target = selectedApp.isEmpty ? nil : selectedApp
        Task { @MainActor in
            let sessionID = await recorder.startCall(for: event, notePath: nil, sourceKind: .manual,
                                                      targetBundleID: target) { session in
                Task { await RecordingCoordinator.finishCall(session: session, event: event) }
            }
            starting = false
            if let sessionID {
                WorkspaceWindowController.shared.showRecording(id: sessionID)
                onClose()
            } else if case .failed(let message) = recorder.state {
                error = message
            } else {
                error = copy("Another recording is already starting or stopping. Try again after it finishes.", "Ya hay otra grabación iniciándose o deteniéndose. Intenta cuando termine.")
            }
        }
    }
}
