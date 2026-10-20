import SwiftUI

struct AgendaView: View {
    let events: [UnifiedEvent]
    let hasAccounts: Bool
    var day: Date? = nil
    var showsHero = true
    var onSelect: ((UnifiedEvent) -> Void)?
    @State private var now = Date()

    private var isToday: Bool { day.map(Calendar.current.isDateInToday) ?? true }
    private var timeline: AgendaTimeline { TimelineBuilder.build(events: events, day: day, now: now) }
    private var heroEvent: UnifiedEvent? {
        guard isToday, showsHero else { return nil }
        return timeline.inProgress.first ?? timeline.next
    }

    var body: some View {
        Group {
            if !hasAccounts && events.isEmpty {
                HalleEmptyState(symbol: "person.crop.circle.badge.plus", title: L10n.text("agenda.noAccounts"),
                                detail: L10n.text("agenda.noAccounts.detail"))
            } else if timeline.isEmpty {
                HalleEmptyState(symbol: "sparkles", title: L10n.text("agenda.empty"),
                                detail: isToday ? L10n.text("agenda.empty.today") : L10n.text("agenda.empty.day"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let heroEvent { MeetingHeroCard(event: heroEvent, now: now, onSelect: onSelect) }
                        if !timeline.allDay.isEmpty { allDaySection }
                        if isToday {
                            let sections = TimelineBuilder.todaySections(timeline.hourGroups.flatMap(\.events), now: now)
                            if !sections.upcoming.isEmpty { timelineSection(events: sections.upcoming, title: PublicUICopy.text("Upcoming", "Próximas"), excluding: heroEvent?.dedupKey) }
                            if !sections.past.isEmpty { timelineSection(events: sections.past, title: PublicUICopy.text("Earlier today", "Más temprano"), excluding: heroEvent?.dedupKey) }
                        } else {
                            timelineSection(events: timeline.hourGroups.flatMap(\.events), title: L10n.text("agenda.schedule"), excluding: nil)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task(id: isToday) {
            guard isToday else { return }
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var allDaySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(L10n.text("agenda.allDay"))
            ForEach(timeline.allDay) { EventRowView(event: $0, onSelect: onSelect) }
        }
    }

    @ViewBuilder private func timelineSection(events: [UnifiedEvent], title: String, excluding key: String?) -> some View {
        let visible = events.filter { $0.dedupKey != key }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader(title)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { EventRowView(event: $0, onSelect: onSelect) }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 2)
    }
}

struct MeetingHeroCard: View {
    let event: UnifiedEvent
    let now: Date
    var onSelect: ((UnifiedEvent) -> Void)?
    @State private var reminderSnapshot: NotificationPlanner.ReminderDiagnosticsSnapshot?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let active = event.startTs <= context.date && context.date < event.endTs
            HalleCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HalleStatusBadge(text: active ? L10n.text("agenda.now") : L10n.text("agenda.next"),
                                         tone: active ? .recording : .info)
                        Spacer()
                        Text(relativeText(now: context.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(event.title).font(.title3.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(event.startTs, format: .dateTime.hour().minute())
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        if let project = event.projectId { Text("·"); Text(AliasStore.shared.projectName(for: project) ?? project) }
                    }.font(.callout).foregroundStyle(.secondary)
                    if let snapshot = reminderSnapshot,
                       let reminder = snapshot.occurrences.first(where: {
                           $0.id == NotificationPlanner.identifier(dedupKey: event.dedupKey, startTs: event.startTs)
                       }) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: reminderSymbol(reminder.state)).foregroundStyle(reminderTone(reminder.state).color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PublicUICopy.text(reminderTitle(reminder.state), reminderTitleES(reminder.state)))
                                    .font(.caption.weight(.medium))
                                Text(reminder.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        if !snapshot.alertsEnabled || !snapshot.soundsEnabled {
                            Text(!snapshot.alertsEnabled ? "macOS alerts are turned off." : "macOS notification sounds are turned off.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("Checking reminder status…", systemImage: "bell.badge").font(.caption).foregroundStyle(.secondary)
                    }
                    MeetingActionButtons(event: event)
                }
            }
            .contentShape(Rectangle()).onTapGesture { onSelect?(event) }
            .task(id: "\(event.dedupKey)|\(event.startTs.timeIntervalSince1970)|\(Int(now.timeIntervalSince1970 / 30))") {
                reminderSnapshot = await NotificationScheduler.shared.reminderDiagnostics(events: [event])
            }
        }
    }

    private func relativeText(now: Date) -> String {
        let active = event.startTs <= now && now < event.endTs
        let target = active ? event.endTs : event.startTs
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguageStore.shared.locale
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: target, relativeTo: now)
        return active
            ? PublicUICopy.text("Ends \(relative)", "Termina \(relative)")
            : PublicUICopy.text("Starts \(relative)", "Comienza \(relative)")
    }

    private func reminderSymbol(_ state: NotificationPlanner.ReminderState) -> String {
        switch state {
        case .scheduled, .lateCatchUp: "bell.badge.fill"
        case .delivered: "bell.slash"
        case .catchUpClaimed: "bell.badge"
        case .quietHours, .disabled, .permissionUnavailable: "bell.slash.fill"
        default: "bell"
        }
    }

    private func reminderTone(_ state: NotificationPlanner.ReminderState) -> HalleStatusTone {
        switch state {
        case .scheduled, .lateCatchUp: .success
        case .quietHours, .outsideHorizon, .notScheduled: .warning
        default: .neutral
        }
    }

    private func reminderTitle(_ state: NotificationPlanner.ReminderState) -> String {
        switch state {
        case .scheduled: "Reminder scheduled"
        case .delivered: "Reminder delivered"
        case .lateCatchUp: "Late reminder scheduled"
        case .quietHours: "Quiet hours"
        case .disabled: "Reminders turned off"
        case .permissionUnavailable: "Permission unavailable"
        case .alreadyStarted: "Reminder window passed"
        case .outsideHorizon: "Outside reminder window"
        case .declined: "Declined meeting"
        case .cancelled: "Meeting cancelled"
        case .allDay: "All-day event"
        case .notScheduled: "Reminder not scheduled"
        case .catchUpClaimed: "Catch-up requested; delivery unconfirmed"
        }
    }

    private func reminderTitleES(_ state: NotificationPlanner.ReminderState) -> String {
        switch state {
        case .scheduled: "Recordatorio programado"
        case .delivered: "Recordatorio enviado"
        case .lateCatchUp: "Recordatorio tardío programado"
        case .quietHours: "Horario silencioso"
        case .disabled: "Recordatorios desactivados"
        case .permissionUnavailable: "Permiso no disponible"
        case .alreadyStarted: "Venció el plazo del recordatorio"
        case .outsideHorizon: "Fuera del plazo de recordatorio"
        case .declined: "Reunión rechazada"
        case .cancelled: "Reunión cancelada"
        case .allDay: "Todo el día"
        case .notScheduled: "Recordatorio no programado"
        case .catchUpClaimed: "Recuperación solicitada; envío sin confirmar"
        }
    }
}
