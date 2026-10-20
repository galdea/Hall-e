import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Pair trusted devices and coordinate meeting segments. Audio remains on the
/// device that records it; this view never offers a remote start command.
struct SharedMeetingsView: View {
    @State private var coordinator = SharedMeetingCoordinator.shared
    @State private var invitationText = ""
    @State private var showConnectConsent = false
    @State private var showDisconnectConfirmation = false
    @State private var deviceToRevoke: SharedDeviceRecord?
    @State private var showNewMeeting = false
    @State private var showNewProject = false
    @State private var projectName = ""
    @State private var projectError: String?
    @State private var projectTargetMeeting: SharedMeetingRecord?

    init(pendingInvitation: String? = nil) {
        _invitationText = State(initialValue: pendingInvitation ?? "")
    }

    var body: some View {
        Form {
            Section("Pair devices") {
                Text("Pair Hall-e on trusted devices to coordinate meetings. Selected titles, projects, optional links and times are encrypted and sent to the coordinator; device and recording-segment status is visible there. Audio stays on the device that records it.")
                    .font(.callout).foregroundStyle(.secondary)
                switch coordinator.credentialsLoadState {
                case .loading:
                    ProgressView("Checking for a saved device link…")
                case .failed(let detail):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Could not check this Mac’s saved device link.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                        Button("Retry Keychain check") { Task { await coordinator.retryCredentialLoad() } }
                    }
                case .unpaired, .paired:
                    if coordinator.isOwner, let invitationURL = coordinator.invitationURL {
                        HStack(alignment: .top, spacing: 16) {
                            if let qr = Self.qrImage(for: invitationURL) {
                                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 148, height: 148)
                                    .accessibilityLabel("Pairing invitation QR code")
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Invitation ready").font(.headline)
                                Text("This link is sensitive and expires. Share it only with the device you want to pair.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Copy invitation link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(invitationURL, forType: .string)
                                }
                                Button("Create a new invitation") { Task { await coordinator.createInvitation() } }
                            }
                        }.padding(.vertical, 4)
                    } else if !coordinator.isPaired || coordinator.isOwner {
                        Button(coordinator.isPaired ? "Create pairing invitation" : "Create workspace & invitation") {
                            Task { await coordinator.createInvitation() }
                        }
                        .disabled(coordinator.isBusy)
                    }
                    if !coordinator.isPaired {
                        TextField("Paste invitation link or code", text: $invitationText, axis: .vertical)
                            .lineLimit(2...4)
                        Button("Connect device…") { showConnectConsent = true }
                            .disabled(invitationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coordinator.isBusy)
                    }
                }
            }

            Section("Linked devices") {
                switch coordinator.credentialsLoadState {
                case .loading:
                    Text("Waiting for the saved-device check to finish…").foregroundStyle(.secondary)
                case .failed:
                    Text("Linked-device details are unavailable until Keychain access is restored.").foregroundStyle(.secondary)
                case .unpaired:
                    Text("No devices are linked yet.").foregroundStyle(.secondary)
                case .paired where coordinator.devices.isEmpty:
                    Text("No devices are linked yet.").foregroundStyle(.secondary)
                case .paired:
                    EmptyView()
                }
                ForEach(coordinator.credentialsLoadState == .paired ? coordinator.devices : []) { device in
                    HStack {
                        Label(device.name, systemImage: "laptopcomputer.and.iphone")
                        Spacer()
                        if device.id == coordinator.deviceID { Text("This device").font(.caption).foregroundStyle(.secondary) }
                        else if coordinator.isOwner {
                            Button("Unlink") { deviceToRevoke = device }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if coordinator.isPaired {
                    Button("Unlink this device…", role: .destructive) { showDisconnectConfirmation = true }
                }
            }

            Section {
                HStack {
                    Text("Shared meetings").font(.headline)
                    Spacer()
                    Button { showNewMeeting = true } label: { Label("New meeting", systemImage: "plus") }
                        .disabled(!coordinator.isPaired || coordinator.isBusy)
                }
                switch coordinator.credentialsLoadState {
                case .loading:
                    Text("Waiting for the saved-device check to finish…").foregroundStyle(.secondary)
                case .failed:
                    Text("Shared meetings are unavailable until Keychain access is restored.").foregroundStyle(.secondary)
                case .unpaired:
                    Text("No shared meetings yet. Create one here or pair another device.").foregroundStyle(.secondary)
                case .paired where coordinator.meetings.isEmpty:
                    Text("No shared meetings yet.").foregroundStyle(.secondary)
                case .paired:
                    EmptyView()
                }
                ForEach(coordinator.credentialsLoadState == .paired ? coordinator.meetings : []) { meeting in
                    meetingRow(meeting)
                }
                Text("Only meeting details and recording-segment status are shared. Full audio stays on the device that captured it.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Meetings") }

            if let status = coordinator.statusMessage {
                Section("Status") { Label(status, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            if let error = coordinator.errorMessage {
                Section("Couldn’t complete that action") { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Devices & shared meetings")
        .toolbar {
            ToolbarItem { Button("Refresh") { Task { await coordinator.refresh() } }.disabled(coordinator.isBusy) }
        }
        .task {
            while !Task.isCancelled {
                await coordinator.refresh()
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
        .confirmationDialog("Connect this device?", isPresented: $showConnectConsent, titleVisibility: .visible) {
            Button("Connect device") {
                let invitation = invitationText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await coordinator.joinInvitation(invitation); invitationText = "" }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connecting links this device to the invitation’s owner and shares meeting titles, project names, times, and recording-segment status. It does not transfer audio.")
        }
        .confirmationDialog("Unlink this device?", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
            Button("Unlink device", role: .destructive) { Task { await coordinator.disconnect() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This device will stop receiving shared meeting updates. Local recordings remain on this device.") }
        .confirmationDialog("Unlink \(deviceToRevoke?.name ?? "device")?", isPresented: Binding(
            get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } }), titleVisibility: .visible) {
            Button("Unlink device", role: .destructive) {
                guard let device = deviceToRevoke else { return }
                Task { await coordinator.revokeDevice(device.id); deviceToRevoke = nil }
            }
            Button("Cancel", role: .cancel) { deviceToRevoke = nil }
        } message: { Text("The device will lose access to shared meeting metadata. Any audio already saved on it remains there.") }
        .sheet(isPresented: $showNewMeeting) { newMeetingSheet }
        .sheet(isPresented: $showNewProject, onDismiss: { projectTargetMeeting = nil }) { newProjectSheet }
    }

    @ViewBuilder private func meetingRow(_ meeting: SharedMeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title).font(.headline)
                Spacer()
                Text(meeting.startAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(meeting.projectName.map { "Project · \($0)" } ?? "No project")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let rawURL = meeting.meetingURL, let url = Self.safeHTTPURL(rawURL) {
                    Menu("Join") {
                        Button("Join without recording") { NSWorkspace.shared.open(url) }
                        if let lease = coordinator.activeLease, lease.sessionId == meeting.id,
                           lease.deviceId != coordinator.deviceID {
                            Button("Take over and record here") { joinWithRecording(meeting, url: url, takeover: true) }
                        } else {
                            Button("Join and record here") { joinWithRecording(meeting, url: url, takeover: false) }
                        }
                    }.menuStyle(.borderlessButton)
                }
                Menu("Project") {
                    Button("No project") { Task { await coordinator.updateProject(meeting, projectName: nil) } }
                    ForEach(AliasStore.shared.projects.filter { !$0.isArchived }.sorted { $0.name < $1.name }) { project in
                        Button(project.name) { Task { await coordinator.updateProject(meeting, projectName: project.name) } }
                    }
                    Divider()
                    Button("Create project…") {
                        projectTargetMeeting = meeting
                        projectName = ""; projectError = nil; showNewProject = true
                    }
                }.menuStyle(.borderlessButton)
            }
            if let lease = coordinator.activeLease, lease.sessionId == meeting.id {
                let owner = coordinator.devices.first(where: { $0.id == lease.deviceId })?.name
                    ?? (lease.deviceId == coordinator.deviceID ? "This device" : "Another device")
                Label("Recording on \(owner)", systemImage: "record.circle.fill").font(.caption).foregroundStyle(.orange)
                ForEach(coordinator.segments.filter { $0.sessionId == meeting.id }) { segment in
                    segmentRow(segment)
                }
                if lease.deviceId != coordinator.deviceID {
                    Button("Take over on this Mac…") { Task { await coordinator.recordHere(meeting, takeOver: true) } }
                        .disabled(coordinator.isBusy)
                } else if coordinator.isRecordingHere {
                    Button("Stop recording on this Mac", role: .destructive) { coordinator.stopRecording() }
                }
            } else {
                ForEach(coordinator.segments.filter { $0.sessionId == meeting.id }) { segment in
                    segmentRow(segment)
                }
                Button("Record here on this Mac…") { Task { await coordinator.recordHere(meeting, takeOver: false) } }
                    .disabled(!coordinator.isPaired || coordinator.isBusy)
            }
        }
        .padding(.vertical, 5)
    }

    private func segmentRow(_ segment: SharedSegmentRecord) -> some View {
        let name = coordinator.devices.first(where: { $0.id == segment.deviceId })?.name
            ?? (segment.deviceId == coordinator.deviceID ? "This device" : "Unlinked device")
        let start = Date(timeIntervalSince1970: segment.startedAtMs / 1_000)
        let end = segment.endedAtMs.map { Date(timeIntervalSince1970: $0 / 1_000) }
        return Label("\(name) · \(start.formatted(date: .omitted, time: .shortened))\(end.map { "–\($0.formatted(date: .omitted, time: .shortened))" } ?? " · \(segment.status)")", systemImage: "waveform")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func joinWithRecording(_ meeting: SharedMeetingRecord, url: URL, takeover: Bool) {
        Task {
            await coordinator.recordHere(meeting, takeOver: takeover)
            if coordinator.isRecordingHere, coordinator.activeLease?.sessionId == meeting.id {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var newMeetingSheet: some View {
        SharedMeetingCreateSheet(projects: AliasStore.shared.projects.filter { !$0.isArchived }, createProject: createProject(named:)) { title, projectName, meetingURL in
            Task { await coordinator.createMeeting(title: title, projectName: projectName, meetingURL: meetingURL) }
            showNewMeeting = false
        } onCancel: { showNewMeeting = false }
        .frame(width: 460)
    }

    private func createProject(named name: String) -> Project? {
        do {
            let project = try AliasStore.shared.createProject(named: name)
            projectError = nil
            Task { await coordinator.refresh() }
            return project
        } catch {
            projectError = error.localizedDescription
            return nil
        }
    }

    private var newProjectSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create local project").font(.title2.weight(.semibold))
            TextField("Project name", text: $projectName)
            if let projectError { Text(projectError).font(.caption).foregroundStyle(.red) }
            HStack { Spacer()
                Button("Cancel") { showNewProject = false }
                Button("Create project") {
                    do {
                        let project = try AliasStore.shared.createProject(named: projectName)
                        projectError = nil; showNewProject = false
                        if let meeting = projectTargetMeeting {
                            Task { await coordinator.updateProject(meeting, projectName: project.name) }
                        } else {
                            Task { await coordinator.refresh() }
                        }
                    } catch { projectError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 400)
    }

    private static func qrImage(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 148, height: 148))
    }

    fileprivate static func safeHTTPURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else { return nil }
        return components.url
    }
}

private struct SharedMeetingCreateSheet: View {
    @State private var projects: [Project]
    let createProject: (String) -> Project?
    let onCreate: (String, String?, String?) -> Void
    let onCancel: () -> Void
    @State private var title = ""
    @State private var projectName = ""
    @State private var meetingURL = ""
    @State private var newProjectName = ""
    @State private var projectError: String?
    @State private var meetingURLError: String?

    init(projects: [Project], createProject: @escaping (String) -> Project?,
         onCreate: @escaping (String, String?, String?) -> Void, onCancel: @escaping () -> Void) {
        _projects = State(initialValue: projects)
        self.createProject = createProject
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            TextField("Meeting title", text: $title)
            Picker("Project", selection: $projectName) {
                Text("No project").tag("")
                ForEach(projects) { Text($0.name).tag($0.name) }
            }
            HStack {
                TextField("New local project name", text: $newProjectName)
                Button("Create project") {
                    if let created = createProject(newProjectName) {
                        if !projects.contains(where: { $0.id == created.id }) { projects.append(created) }
                        projectName = created.name; newProjectName = ""; projectError = nil
                    } else { projectError = "Enter a project name that can be saved." }
                }.disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let projectError { Text(projectError).font(.caption).foregroundStyle(.red) }
            TextField("Meeting link (optional)", text: $meetingURL)
                .onChange(of: meetingURL) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    meetingURLError = !trimmed.isEmpty && SharedMeetingsView.safeHTTPURL(trimmed) == nil
                        ? "Enter an http or https meeting link." : nil
                }
            if let meetingURLError { Text(meetingURLError).font(.caption).foregroundStyle(.red) }
            Text("The meeting will be shared as metadata only. Start recording separately on the device that should capture its local microphone.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel", action: onCancel)
                Button("Create meeting") {
                    onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), projectName.isEmpty ? nil : projectName,
                             meetingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : meetingURL)
                }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meetingURLError != nil)
            }
        }.formStyle(.grouped).padding(12).frame(width: 440, height: 300)
    }
}
