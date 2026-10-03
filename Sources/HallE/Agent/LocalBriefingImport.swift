import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The agent receives an explicit export; import cannot issue provider requests.
enum LocalBriefingImport {
    static func evidencePacket(session: RecordingSession, transcript: Transcript) -> String {
        """
        # Hall-E local agent evidence packet
        Schema: \(MeetingBriefing.schema)
        Session: \(session.id.uuidString)
        Transcript hash: \(transcript.contentHash)
        Title: \(session.eventTitle)

        Return one JSON MeetingBriefing with objectives, tasks, decisions, risks,
        openQuestions and milestones. Each item needs id, title, priority,
        confidence (0...1), and evidence [{utteranceIndex,start,end,excerpt}].
        Use exact excerpts and timestamps within the cited utterance. Do not infer
        a person's identity from anonymous speaker labels. Leave unsupported owner
        and explicitDate null; ownerKind must be unassigned when unknown.
        No external send or calendar write is authorized by this packet.
        The user reviews semantic claims before applying the import.

        ## Transcript evidence
        \(transcript.evidenceTranscript)
        """
    }

    static func decode(_ data: Data, transcript: Transcript) throws -> MeetingBriefing {
        let briefing = try JSONDecoder().decode(MeetingBriefing.self, from: data)
        try MeetingBriefingValidator.validate(briefing, transcript: transcript)
        return briefing
    }

    static func actions(_ briefing: MeetingBriefing) -> String {
        briefing.tasks.map { item in
            var line = "- [ ] " + inline(item.title)
            if let owner = item.ownerName, item.ownerKind != .unassigned {
                line += " (@\(inline(owner).replacingOccurrences(of: " ", with: "_")))"
            }
            line += " " + item.evidence.map { "[[#Evidence u\($0.utteranceIndex)|u\($0.utteranceIndex) @ \(Int($0.start))s]]" }.joined(separator: " ")
            if let date = item.explicitDate { line += " — due " + inline(date) }
            line += " <!-- hall-e:briefing-task:" + inline(item.id).replacingOccurrences(of: "--", with: "") + " -->"
            return line
        }.joined(separator: "\n")
    }

    static func evidenceAppendix(_ briefing: MeetingBriefing, transcript: Transcript) -> String {
        let indices = Set((briefing.objectives + briefing.tasks + briefing.decisions + briefing.risks + briefing.openQuestions + briefing.milestones).flatMap(\.evidence).map(\.utteranceIndex)).sorted()
        return indices.map { index in
            let segment = transcript.segments[index]
            return "### Evidence u\(index)\n\n\(String(format: "%.2f", segment.start))–\(String(format: "%.2f", segment.start + segment.duration))s · \(segment.speaker.map { "Anonymous speaker \($0 + 1)" } ?? segment.track)\n\n> \(segment.text.replacingOccurrences(of: "\n", with: "\n> "))"
        }.joined(separator: "\n\n")
    }

    @MainActor static func apply(_ briefing: MeetingBriefing, session: RecordingSession, transcript: Transcript,
                                 service: MeetingNoteService, notePath: String) async throws {
        // Revalidate the current revision at commit time, not only when opening the review.
        guard let current = TranscriptStore.load(session), current.contentHash == transcript.contentHash else {
            throw BriefingValidationError.transcriptMismatch
        }
        try MeetingBriefingValidator.validate(briefing, transcript: current)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let directory = session.folderURL.appendingPathComponent("LocalBriefings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let revision = transcript.contentHash.prefix(12).description + "-" + UUID().uuidString
        let jsonURL = directory.appendingPathComponent(revision + ".json")
        let markdown = BriefingRenderer.markdown(briefing) + "\n\n" + evidenceAppendix(briefing, transcript: current)
        try encoder.encode(briefing).write(to: jsonURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jsonURL.path)
        let writer = VaultWriter(vaultURL: service.vaultURL), paths = VaultPathBuilder(config: service.config)
        try writer.mergeSection(relativePath: notePath, section: "briefing", newContent: markdown,
                                headingAnchor: "Briefing", mode: .replace, pathBuilder: paths)
        // Preserve existing checkboxes, completion state and user-written commitments.
        if !briefing.tasks.isEmpty {
            try writer.mergeSection(relativePath: notePath, section: "actions", newContent: newActions(briefing, existingNote: (try? String(contentsOf: paths.absoluteURL(notePath, vaultURL: service.vaultURL), encoding: .utf8)) ?? ""),
                                    headingAnchor: "Actions", mode: .appendLines, pathBuilder: paths)
        }
        try writer.updateFrontmatter(relativePath: notePath, key: "briefing_status", value: "completed-local", pathBuilder: paths)
        var updated = session
        updated.briefingJob = .init(status: .completed, attemptCount: session.briefingJob?.attemptCount ?? 0,
            transcriptHash: current.contentHash, promptVersion: briefing.promptVersion, model: briefing.model,
            completedAt: Date())
        updated.save()
        await VaultIndex.shared.reindex(refreshIntelligence: false); AppState.shared.refreshRecordings()
    }
    static func newActions(_ briefing: MeetingBriefing, existingNote: String) -> String {
        actions(briefing).components(separatedBy: "\n").filter { line in
            guard let range = line.range(of: "<!-- hall-e:briefing-task:"), let end = line.range(of: " -->", range: range.lowerBound..<line.endIndex) else { return true }
            return !existingNote.contains(String(line[range.lowerBound..<end.upperBound]))
        }.joined(separator: "\n")
    }
    private static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct LocalBriefingControls: View {
    let session: RecordingSession
    @State private var staged: MeetingBriefing?
    @State private var transcript: Transcript?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Local agent briefing", systemImage: "doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button("Export evidence…") { export() }.disabled(busy)
                Button("Review briefing JSON…") { select() }.disabled(busy)
            }
            Text("Export only when you want to give the agent this transcript. Imported claims are checked against its exact revision, then reviewed here before they become notes and commitments.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(isPresented: Binding(get: { staged != nil }, set: { if !$0 { staged = nil } })) {
            if let staged, let transcript {
                LocalBriefingReview(briefing: staged, busy: busy, error: error,
                    cancel: { self.staged = nil }, apply: { apply(staged, transcript: transcript) })
            }
        }
    }
    private func apply(_ briefing: MeetingBriefing, transcript: Transcript) {
        guard let service = MeetingNoteService.make(), let path = session.notePath else {
            error = "Connect the vault and meeting note before importing."; return
        }
        busy = true; error = nil
        Task {
            do { try await LocalBriefingImport.apply(briefing, session: session, transcript: transcript, service: service, notePath: path); staged = nil }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    private func export() {
        guard let transcript = TranscriptStore.load(session) else { error = "No saved transcript is available."; return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "hall-e-evidence-\(session.id.uuidString).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(LocalBriefingImport.evidencePacket(session: session, transcript: transcript).utf8).write(to: url, options: .atomic); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func select() {
        guard let transcript = TranscriptStore.load(session) else { error = "No saved transcript is available."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let value = try LocalBriefingImport.decode(Data(contentsOf: url), transcript: transcript)
            self.transcript = transcript; staged = value; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct LocalBriefingReview: View {
    let briefing: MeetingBriefing
    let busy: Bool
    let error: String?
    let cancel: () -> Void
    let apply: () -> Void
    private var items: [BriefingItem] {
        var items = briefing.objectives
        items.append(contentsOf: briefing.tasks); items.append(contentsOf: briefing.decisions)
        items.append(contentsOf: briefing.risks); items.append(contentsOf: briefing.openQuestions)
        items.append(contentsOf: briefing.milestones)
        return items
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(briefing.headline).font(.title2)
            Text("Review what each claim says; matching excerpts alone cannot prove an agent's interpretation.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in claim(item) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel", action: cancel).disabled(busy)
                Spacer()
                Button("Apply reviewed briefing", action: apply).buttonStyle(.borderedProminent).disabled(busy)
            }
        }.padding(22).frame(width: 640, height: 650)
    }
    private func claim(_ item: BriefingItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline)
            if let detail = item.detail { Text(detail) }
            Text("Owner: \(item.ownerName ?? "Unassigned") · Due: \(item.explicitDate ?? "Unspecified")").font(.caption)
            ForEach(item.evidence, id: \.self) { evidence in
                Text("u\(evidence.utteranceIndex) · \(String(format: "%.2f", evidence.start))s: “\(evidence.excerpt)”")
                    .font(.caption).textSelection(.enabled)
            }
            Divider()
        }
    }
}
