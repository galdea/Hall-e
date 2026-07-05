import SwiftUI
import AppKit

struct EventRowView: View {
    let event: UnifiedEvent
    @State private var hovering = false

    private var isCancelled: Bool { event.status == "cancelled" }
    private var isDeclined: Bool { event.effectiveResponse == "declined" }
    private var isTentative: Bool { event.effectiveResponse == "tentative" }
    private var inProgress: Bool { event.startTs <= Date() && Date() < event.endTs && !event.isAllDay }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            timeColumn
            VStack(alignment: .leading, spacing: 3) {
                titleRow
                metaRow
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(inProgress ? Color.accentColor.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            if inProgress {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                    .frame(width: 3).padding(.vertical, 4)
            }
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            if event.isAllDay {
                Text("all-day").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(event.startTs, format: .dateTime.hour().minute())
                    .font(.callout.monospacedDigit())
                Text(event.endTs, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, alignment: .trailing)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(event.sources.prefix(4).enumerated()), id: \.offset) { _, src in
                Circle().fill(Color(hex: src.colorHex ?? "") ?? .secondary)
                    .frame(width: 7, height: 7)
            }
            Text(event.title)
                .font(.callout).fontWeight(inProgress ? .semibold : .regular)
                .strikethrough(isCancelled)
                .foregroundStyle(isCancelled || isDeclined ? .secondary : .primary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 6) {
            if let project = event.projectId {
                Text(project)
                    .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            if isTentative { statusTag("tentative", .orange) }
            if isDeclined { statusTag("declined", .red) }
            if let loc = event.location, !loc.isEmpty, event.meetingURL == nil {
                Label(loc, systemImage: "mappin.and.ellipse")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func statusTag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).foregroundStyle(color)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let urlString = event.meetingURL, let url = URL(string: urlString) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "video.fill")
                }
                .buttonStyle(.borderless).help("Join meeting")
            }
            Menu {
                if let link = event.htmlLink, let url = URL(string: link) {
                    Button("Open in Calendar") { NSWorkspace.shared.open(url) }
                }
                Button("Prepare note") { Features.current.prepareNote(for: event) }
                if Features.current.canOpenObsidian {
                    Button("Open project note") { Features.current.openInObsidian(event) }
                }
                Button("Start recording…") { Features.current.startRecording(for: event) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .opacity(hovering ? 1 : 0.4)
        }
    }
}
