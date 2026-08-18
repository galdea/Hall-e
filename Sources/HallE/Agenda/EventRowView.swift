import SwiftUI
import AppKit

/// When an agenda row offers playback and transcript controls for a recording.
enum MeetingArtifactAvailability {
    /// A finished capture is reachable immediately. Gating on the meeting's
    /// scheduled end hid recordings stopped early — the row looked exactly as
    /// it did before recording, which reads as the recording having been
    /// deleted. The event-end fallback keeps sessions that never stamped
    /// `endedAt` (a crash mid-recording, or a pre-`endedAt` build) reachable.
    static func showsArtifacts(session: RecordingSession, eventEnd: Date, now: Date) -> Bool {
        session.isFinished || eventEnd <= now
    }
}

struct EventRowView: View {
    let event: UnifiedEvent
    var emphasizesActions = false
    var onSelect: ((UnifiedEvent) -> Void)?
    @State private var hovering = false
    @State private var appState = AppState.shared
    @State private var playback = RecordingPlaybackService.shared
    @State private var artifactMode: MeetingArtifactMode?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        let active = event.startTs <= now && now < event.endTs && !event.isAllDay
        let soon = event.startTs > now && event.startTs.timeIntervalSince(now) < 30 * 60
        let session = appState.recordingsByEvent[event.dedupKey]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                timeColumn
                VStack(alignment: .leading, spacing: 4) {
                    titleRow(active: active)
                    metaRow
                    if emphasizesActions || active || soon {
                        MeetingActionButtons(event: event, compact: true)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 4)
                trailingActions(now: now, session: session,
                                showJoin: !(emphasizesActions || active || soon))
            }
            if let session, artifactMode != nil {
                MeetingArtifactPanel(session: session, mode: $artifactMode)
                    .padding(.leading, 58)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(active ? Color.accentColor.opacity(0.09) : hovering ? Color.primary.opacity(0.035) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if active { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3).padding(.vertical, 4) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(event) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(event.title), \(event.startTs.formatted(date: .omitted, time: .shortened))")
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if event.isAllDay {
                Text(L10n.text("agenda.allDay")).font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(event.startTs, format: .dateTime.hour().minute()).font(.callout.monospacedDigit())
                Text(event.endTs, format: .dateTime.hour().minute()).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }.frame(width: 48, alignment: .trailing)
    }

    private func titleRow(active: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(event.sources.prefix(3).enumerated()), id: \.offset) { _, source in
                Circle().fill(Color(hex: source.colorHex ?? "") ?? .secondary).frame(width: 7, height: 7)
            }
            Text(event.title)
                .font(.callout).fontWeight(active ? .semibold : .regular)
                .strikethrough(event.status == "cancelled")
                .foregroundStyle(event.status == "cancelled" || event.effectiveResponse == "declined" ? .secondary : .primary)
                .lineLimit(2)
        }
    }

    @ViewBuilder private var metaRow: some View {
        HStack(spacing: 6) {
            if let project = event.projectId { HalleStatusBadge(text: project, tone: .info) }
            if event.effectiveResponse == "tentative" { HalleStatusBadge(text: "Tentative", tone: .warning) }
            if event.effectiveResponse == "declined" { HalleStatusBadge(text: "Declined", tone: .error) }
            if let location = event.location, !location.isEmpty, event.meetingURL == nil {
                Label(location, systemImage: "mappin.and.ellipse").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func trailingActions(now: Date, session: RecordingSession?, showJoin: Bool) -> some View {
        HStack(spacing: 5) {
            if let session, MeetingArtifactAvailability.showsArtifacts(
                session: session, eventEnd: event.endTs, now: now) {
                if session.hasPlayableAudio {
                    Button {
                        artifactMode = .recording
                        playback.toggle(session)
                    } label: {
                        Image(systemName: playback.activeSessionID == session.id && playback.isPlaying
                              ? "pause.circle.fill" : "play.circle.fill")
                    }
                    .buttonStyle(.borderless).help("Play recording")
                }
                // Always tappable: an unfinished transcript still has to open the
                // panel, which reports progress and offers playback. A disabled
                // button here is indistinguishable from "there is no recording".
                Button { artifactMode = artifactMode == .transcript ? nil : .transcript } label: {
                    Image(systemName: "text.quote")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(transcriptTone(session.transcriptStatus).color)
                .help(transcriptHelp(session.transcriptStatus))
            }
            if showJoin, let link = event.meetingURL, URL(string: link) != nil {
                Button { MeetingLauncher.join(event) } label: { Image(systemName: "video.fill") }
                    .buttonStyle(.borderless).help(L10n.text("meeting.join"))
            }
            Menu {
                if let link = event.htmlLink, let url = URL(string: link) {
                    Button(L10n.text("meeting.openCalendar")) { NSWorkspace.shared.open(url) }
                }
                Button(L10n.text("meeting.prepareNote")) { Features.current.prepareNote(for: event) }
                if Features.current.canOpenObsidian {
                    Button(L10n.text("meeting.openProjectNote")) { Features.current.openInObsidian(event) }
                }
                Button(L10n.text("meeting.startRecording")) { Features.current.startRecording(for: event) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().opacity(hovering ? 1 : 0.55)
        }
    }

    private func transcriptTone(_ status: TranscriptStatus) -> HalleStatusTone {
        switch status { case .completed: .success; case .failed: .error; case .inProgress, .pending: .warning }
    }
    private func transcriptHelp(_ status: TranscriptStatus) -> String {
        switch status { case .completed: "Copy transcript"; case .failed: "Transcription failed"; case .inProgress: "Transcribing…"; case .pending: "Transcript pending" }
    }
}

struct MeetingActionButtons: View {
    let event: UnifiedEvent
    var compact = false
    @State private var recorder = RecordingService.shared

    var body: some View {
        HStack(spacing: 7) {
            if let link = event.meetingURL, URL(string: link) != nil {
                action(L10n.text("meeting.join"), "video.fill", prominent: true) { MeetingLauncher.join(event) }
            }
            action(L10n.text("meeting.note"), "note.text") { Features.current.prepareNote(for: event) }
            if recorder.isRecording, recorder.currentSession?.eventDedupKey == event.dedupKey {
                action("Stop", "stop.fill", tone: .red) { recorder.stop() }
            } else {
                action(L10n.text("meeting.record"), "record.circle", tone: .red) { Features.current.startRecording(for: event) }
                    .disabled(recorder.isRecording)
            }
        }
    }

    @ViewBuilder private func action(_ title: String, _ symbol: String, prominent: Bool = false,
                                     tone: Color? = nil, perform: @escaping () -> Void) -> some View {
        if prominent {
            actionButton(title, symbol, tone: tone, perform: perform).buttonStyle(.borderedProminent)
        } else {
            actionButton(title, symbol, tone: tone, perform: perform).buttonStyle(.bordered)
        }
    }

    private func actionButton(_ title: String, _ symbol: String, tone: Color?,
                              perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            if compact { Image(systemName: symbol) } else { Label(title, systemImage: symbol) }
        }
        .controlSize(compact ? .small : .regular).tint(tone).help(title).accessibilityLabel(title)
    }
}
