import Foundation
import AppKit
import SwiftUI

struct PreparationReceipt: Codable, Equatable {
    var occurrenceKey: String
    var snoozedUntil: Date?
    var expiresAt: Date
}

/// No network or model work happens on the five-minute timer.
enum MeetingPreparationPolicy {
    static func key(_ event: UnifiedEvent) -> String { event.dedupKey + "|" + String(event.startTs.timeIntervalSince1970) }
    static func candidate(events: [UnifiedEvent], now: Date, lastSync: Date?, receipts: [PreparationReceipt],
                          enabled: Bool, quiet: Bool) -> UnifiedEvent? {
        guard enabled, !quiet, let lastSync, now.timeIntervalSince(lastSync) >= -60,
              now.timeIntervalSince(lastSync) <= 15 * 60 else { return nil }
        return events.filter { event in
            let remaining = event.startTs.timeIntervalSince(now)
            guard !event.isAllDay, event.status != "cancelled", event.effectiveResponse != "declined",
                  remaining > 0, remaining <= 300,
                  event.meetingURL != nil || event.attendees.contains(where: { !$0.isSelf && $0.responseStatus != "declined" }) else { return false }
            if let receipt = receipts.first(where: { $0.occurrenceKey == key(event) }) {
                return receipt.snoozedUntil.map { $0 <= now } ?? false
            }
            return true
        }.sorted { $0.startTs == $1.startTs ? $0.dedupKey < $1.dedupKey : $0.startTs < $1.startTs }.first
    }
    static func quiet(at now: Date, start: Int, end: Int, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return start <= end ? (start..<end).contains(hour) : hour >= start || hour < end
    }
}

@MainActor final class MeetingPreparationController {
    static let shared = MeetingPreparationController()
    private var timer: Timer?
    private var panel: NSPanel?
    private var shownEvent: UnifiedEvent?
    private var receipts: [PreparationReceipt] = []
    private let storageKey = "meetingPreparationReceipts.v1"

    func start() {
        guard timer == nil else { return }
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            receipts = (try? JSONDecoder().decode([PreparationReceipt].self, from: data)) ?? []
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }
    private func tick() {
        let now = Date(), state = AppState.shared
        receipts.removeAll { $0.expiresAt < now }
        if let shown = shownEvent,
           !state.agenda.contains(where: { $0.dedupKey == shown.dedupKey && $0.startTs == shown.startTs && $0.status != "cancelled" && $0.effectiveResponse != "declined" && $0.startTs > now }) {
            panel?.close(); panel = nil; shownEvent = nil
        }
        guard AppPreferences.meetingPreparationEnabled && AppPreferences.notificationsEnabled else {
            panel?.close(); panel = nil; shownEvent = nil; return
        }
        guard panel?.isVisible != true,
              let event = MeetingPreparationPolicy.candidate(events: state.agenda.filter { event in
                    event.sources.contains { source in state.accounts.contains { account in
                        account.email == source.accountEmail && account.lastSyncError == nil && !account.needsReauth
                            && account.lastSyncAt.map { now.timeIntervalSince($0) <= 15 * 60 } == true
                    } }
                }, now: now, lastSync: state.lastSyncAt,
                receipts: receipts, enabled: true,
                quiet: MeetingPreparationPolicy.quiet(at: now, start: AppPreferences.quietHoursStart, end: AppPreferences.quietHoursEnd)) else { return }
        shownEvent = event
        acknowledge(event, until: nil)
        let project = event.projectId.flatMap { id in AliasStore.shared.projects.first { $0.id == id } }
        let notes = state.vaultDocuments.filter { document in
            document.eventId == event.dedupKey || (project.map { AliasStore.shared.references(document.project, project: $0) } ?? false)
        }.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(3)
        let actions = state.actionItems.filter { action in !action.isCompleted && (action.eventId == event.dedupKey || (project.map { project in AliasStore.shared.references(action.project, project: project) } ?? false)) }.prefix(6)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = PublicUICopy.text("Meeting preparation", "Preparación de reunión")
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MeetingPreparationView(event: event, project: project?.name,
            notes: Array(notes), actions: Array(actions), lastSync: state.lastSyncAt,
            open: { [weak self] in self?.dismiss(); WorkspaceWindowController.shared.showMeeting(dedupKey: event.dedupKey) },
            snooze: { [weak self] in self?.acknowledge(event, until: min(Date().addingTimeInterval(120), event.startTs)); self?.dismiss() },
            dismiss: { [weak self] in self?.dismiss() }))
        panel.center(); panel.orderFrontRegardless(); self.panel = panel
    }
    private func acknowledge(_ event: UnifiedEvent, until: Date?) {
        let key = MeetingPreparationPolicy.key(event)
        receipts.removeAll { $0.occurrenceKey == key }
        receipts.append(.init(occurrenceKey: key, snoozedUntil: until, expiresAt: event.endTs.addingTimeInterval(86400)))
        if let data = try? JSONEncoder().encode(receipts) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
    private func dismiss() { panel?.close(); panel = nil; shownEvent = nil }
}

struct MeetingPreparationView: View {
    let event: UnifiedEvent
    let project: String?
    let notes: [VaultDocument]
    let actions: [IndexedActionItem]
    let lastSync: Date?
    let open: () -> Void
    let snooze: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(PublicUICopy.text("Starting soon", "Comienza pronto"), systemImage: "calendar.badge.clock").font(.caption).foregroundStyle(.secondary)
            Text(event.title).font(.title2.weight(.semibold)).lineLimit(3)
            HStack { Text(event.startTs, style: .time); if let project { Text("· " + project) } }
            Text(event.attendees.compactMap { $0.name ?? $0.email }.joined(separator: " · ")).font(.caption).lineLimit(2)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(PublicUICopy.text("Open commitments", "Compromisos pendientes")).font(.headline)
                    if actions.isEmpty { Text(PublicUICopy.text("No saved commitments in this context.", "No hay compromisos guardados en este contexto." )).foregroundStyle(.secondary) }
                    ForEach(actions) { item in Label(item.task, systemImage: "square").font(.callout) }
                    Text(PublicUICopy.text("Recent context", "Contexto reciente")).font(.headline)
                    ForEach(notes) { note in Text(note.title).font(.callout); Text(note.path).font(.caption2).foregroundStyle(.secondary) }
                    if notes.isEmpty { Text(PublicUICopy.text("No saved project context yet.", "Aún no hay contexto de proyecto guardado.")).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let lastSync { Text("Calendar updated " + lastSync.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
            HStack {
                Button(PublicUICopy.text("Dismiss", "Cerrar"), action: dismiss)
                Button(PublicUICopy.text("Snooze 2 min", "Posponer 2 min"), action: snooze)
                Spacer(); Button(PublicUICopy.text("Open meeting", "Abrir reunión"), action: open).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 480, height: 460)
    }
}
