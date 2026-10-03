import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GRDB

struct WeeklyReviewView: View {
    let model: WorkspaceViewModel
    @State private var anchor = Date()
    @State private var imported: WeeklyContextEnvelope?
    @State private var staged: WeeklyContextEnvelope?
    @State private var receipts: [CalendarSyncReceipt] = []
    @State private var indexedAt: Date?
    @State private var error: String?
    @State private var refreshing = false
    private var interval: DateInterval {
        var calendar = Calendar.current; calendar.firstWeekday = 2
        return calendar.dateInterval(of: .weekOfYear, for: anchor)!
    }
    private var importURL: URL { AppPaths.appSupport.appendingPathComponent("weekly-context.v1.json") }
    private var sources: [WeeklyContextSource] {
        var result = imported?.sources ?? []
        for calendar in model.appState.calendarSources.filter(\.isSelected) {
            let receipt = receipts.filter { $0.accountEmail == calendar.accountEmail && $0.calendarID == calendar.calendarId && $0.coveredFrom <= interval.start && $0.coveredTo >= interval.end }.max { $0.fetchedAt < $1.fetchedAt }
            let best = receipt ?? receipts.filter { $0.accountEmail == calendar.accountEmail && $0.calendarID == calendar.calendarId }.max { $0.fetchedAt < $1.fetchedAt }
            result.append(WeeklyContextSource(id: "local-calendar-" + calendar.id, kind: .calendar, label: calendar.summary,
                scope: calendar.accountEmail + " / " + calendar.calendarId, authorized: true, authorizationReference: "selected-calendar",
                collectedAt: best?.fetchedAt ?? .distantPast, coveredFrom: best?.coveredFrom ?? interval.start,
                coveredTo: best?.coveredTo ?? interval.end, completeScope: receipt != nil,
                items: model.appState.agenda.filter { $0.status != "cancelled" && $0.effectiveResponse != "declined" && $0.sources.contains(where: { $0.accountEmail == calendar.accountEmail && $0.calendarId == calendar.calendarId }) }.map {
                    WeeklyContextItem(id: $0.dedupKey, title: $0.title, detail: $0.startTs.formatted() + " – " + $0.endTs.formatted(), occurredAt: $0.startTs, citation: $0.htmlLink ?? "hall-e:event:" + $0.dedupKey)
                }, error: nil))
        }
        if ObsidianVaultConfig.load() != nil {
            result.append(WeeklyContextSource(id: "local-vault-tasks", kind: .tasks, label: "Hall-E vault commitments",
                scope: "Configured Hall-E vault only; other task systems require an import", authorized: true,
                authorizationReference: "configured-vault", collectedAt: indexedAt ?? .distantPast,
                coveredFrom: interval.start, coveredTo: interval.end, completeScope: false,
                items: model.appState.actionItems.filter { !$0.isCompleted }.map {
                    WeeklyContextItem(id: $0.id, title: $0.task, detail: "Owner: \($0.owner ?? "Unassigned") · Due: \($0.dueDate ?? "Unspecified")", occurredAt: nil, citation: $0.notePath)
                }, error: nil))
        }
        return result
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Weekly review").font(.title2.weight(.semibold))
                Text("An on-demand view across authorized work and personal context. No recurring schedule is configured. Coverage refers to each listed scope, not every account or part of your life.")
                    .font(.caption).foregroundStyle(.secondary)
                DatePicker("Week containing", selection: $anchor, displayedComponents: .date)
                HStack {
                    Button("Refresh calendar week") { refresh() }.disabled(refreshing)
                    Button("Import context…") { selectImport() }
                    Button("Export review…") { export() }
                    if refreshing { ProgressView().controlSize(.small) }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(WeeklyContextSource.Kind.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind.rawValue.capitalized).font(.headline)
                        let matching = sources.filter { $0.kind == kind }
                        if matching.isEmpty { Label("Not connected or imported", systemImage: "link.badge.plus").font(.caption).foregroundStyle(.secondary) }
                        ForEach(matching) { source in
                            let coverage = source.coverage(for: interval, now: Date())
                            HStack { Text(source.label).font(.callout.weight(.medium)); Spacer(); Text(coverage.rawValue.capitalized).font(.caption).foregroundStyle(coverage == .current ? Color.green : .orange) }
                            Text(source.scope).font(.caption).foregroundStyle(.secondary)
                            Text("Collected: " + source.collectedAt.formatted()).font(.caption2).foregroundStyle(.secondary)
                            if coverage != .unauthorized && coverage != .unavailable {
                                ForEach(Array(source.items.filter { $0.occurredAt.map { interval.contains($0) && $0 < interval.end } ?? true }.prefix(12))) { item in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.callout)
                                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                        Text(item.citation).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    }.padding(.vertical, 3)
                                }
                                if source.items.count > 12 { Text("Additional items are available in the exported review.").font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let failure = source.error { Text(failure).font(.caption).foregroundStyle(.red) }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(18)
        }
        .task { await loadLocal(); if let data = try? Data(contentsOf: importURL) { imported = try? WeeklyContextContract.decode(data) } }
        .sheet(isPresented: Binding(get: { staged != nil }, set: { if !$0 { staged = nil } })) {
            if let staged {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review imported source scopes").font(.title2)
                    Text("Use only context you are authorized to include. This imports local data and does not connect accounts or grant remote permissions.").font(.caption)
                    List(staged.sources) { source in
                        VStack(alignment: .leading) { Text(source.label); Text(source.scope).font(.caption); Text("\(source.authorized ? "Authorized receipt" : "Excluded: not authorized") · \(source.items.count) cited items").font(.caption2) }
                    }
                    HStack {
                        Button("Cancel") { self.staged = nil }; Spacer()
                        Button("Use approved context locally") {
                            do {
                                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                try encoder.encode(staged).write(to: importURL, options: .atomic)
                                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: importURL.path)
                                imported = staged; self.staged = nil; error = nil
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(22).frame(width: 600, height: 420)
            }
        }
    }
    private func loadLocal() async {
        receipts = (try? await AppDatabase.shared.dbQueue.read { try CalendarSyncReceipt.fetchAll($0) }) ?? []
        indexedAt = await VaultIndex.shared.lastIndexedAt
    }
    private func refresh() {
        refreshing = true
        Task { await SyncCoordinator.shared.syncRange(interval.start, interval.end); await loadLocal(); refreshing = false }
    }
    private func selectImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { staged = try WeeklyContextContract.decode(Data(contentsOf: url)); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "hall-e-weekly-review.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(WeeklyContextContract.markdown(sources: sources, interval: interval, now: Date()).utf8).write(to: url, options: .atomic); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
