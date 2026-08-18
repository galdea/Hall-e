import SwiftUI

enum PopoverMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String { L10n.text("popover.\(rawValue)") }
}

/// Which period the week/month tabs point at. Hall-e lives in the menu bar for
/// days at a time and the popover keeps one hosting controller for the whole
/// run, so this has to be reset deliberately — otherwise the month grid keeps
/// selecting whichever day was current at launch.
struct PopoverPeriodSelection: Equatable {
    var anchor: Date
    var selectedDay: Date

    init(now: Date = Date(), calendar: Calendar = .current) {
        anchor = now
        selectedDay = calendar.startOfDay(for: now)
    }

    /// Idempotent: already showing today writes nothing, so reopening the
    /// popover on the same day does not churn SwiftUI state.
    mutating func resetToToday(now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        if !calendar.isDate(anchor, inSameDayAs: today) { anchor = now }
        if selectedDay != today { selectedDay = today }
    }

    mutating func shiftMonth(_ direction: Int, calendar: Calendar = .current) {
        guard let shifted = calendar.date(byAdding: .month, value: direction, to: anchor) else { return }
        anchor = shifted
        // Land on the month's first day: the previously selected day number may
        // not exist in the new month, and it is never "current" there anyway.
        selectedDay = calendar.date(from: calendar.dateComponents([.year, .month], from: shifted))
            ?? calendar.startOfDay(for: shifted)
    }

    mutating func shiftWeek(_ direction: Int, calendar: Calendar = .current) {
        guard let shifted = calendar.date(byAdding: .day, value: 7 * direction, to: anchor) else { return }
        anchor = shifted
    }
}

/// Root of the menu-bar popover: header, a Day / Week / Month switcher, and the
/// matching agenda content — all in one component.
struct PopoverRootView: View {
    @State private var appState = AppState.shared
    @State private var mode: PopoverMode = {
        ProcessInfo.processInfo.environment["HALLE_DEBUG_POPOVER_MODE"]
            .flatMap(PopoverMode.init(rawValue:)) ?? .day
    }()
    @State private var selection = PopoverPeriodSelection()
    @State private var syncedPeriods = Set<String>()
    @State private var language = AppLanguageStore.shared

    private var cal: Calendar { var c = Calendar.current; c.timeZone = .current; return c }

    private var anchor: Date { selection.anchor }                        // reference date for week/month

    /// Week = a rolling 7-day window starting at the anchor's day (default today),
    /// so it shows the next 7 days rather than the calendar week's past days.
    private var weekInterval: DateInterval {
        let start = cal.startOfDay(for: anchor)
        return DateInterval(start: start, end: cal.date(byAdding: .day, value: 7, to: start)!)
    }
    private var visibleInterval: DateInterval {
        mode == .month ? TimelineBuilder.periodInterval(scope: .month, anchor: anchor) : weekInterval
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeBar
            Divider()
            if let error = appState.lastSyncError { syncError(error) }
            RecordingPromptBanner()
            content
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 460, height: 620)
        .environment(\.locale, language.locale)
        .id(language.language)
        .onChange(of: mode) { _, newMode in
            // Re-entering Month should present the current day, not the day that
            // happened to be selected when the tab was last left.
            if newMode == .month { goToToday() }
            syncVisiblePeriod()
        }
        .onChange(of: selection.anchor) { _, _ in syncVisiblePeriod() }
        .onReceive(NotificationCenter.default.publisher(for: .hallePopoverWillShow)) { _ in
            goToToday()
        }
    }

    // MARK: - Header

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide)).font(.headline)
                    HStack(spacing: 5) {
                        Text(context.date, style: .time)
                        if appState.isSyncing {
                            ProgressView().controlSize(.mini)
                        } else if let last = appState.lastSyncAt {
                            Text("· " + L10n.format("popover.synced", last.formatted(date: .omitted, time: .shortened)))
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                SyncHealthButton()
                Button { SettingsWindowController.shared.show() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help(L10n.text("common.settings"))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: - Mode switcher + period nav

    private var modeBar: some View {
        VStack(spacing: 6) {
            Picker("", selection: $mode) {
                ForEach(PopoverMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if mode != .day {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Text(periodLabel).font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless)
                }
                HStack {
                    Button(L10n.text("workspace.today")) { goToToday() }.buttonStyle(.link).font(.caption)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .day:
            AgendaView(events: appState.agenda, hasAccounts: !appState.accounts.isEmpty)
        case .week:
            weekView
        case .month:
            monthView
        }
    }

    private var weekView: some View {
        let days = TimelineBuilder.daySummaries(in: weekInterval, events: appState.agenda).map(\.day)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(days, id: \.timeIntervalSince1970) { day in
                    let timeline = TimelineBuilder.build(events: appState.agenda, day: day)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(day, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(cal.isDateInToday(day) ? Color.accentColor : .secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        if timeline.isEmpty {
                            Text("—").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 14)
                        } else {
                            ForEach(timeline.allDay + timeline.hourGroups.flatMap(\.events)) {
                                EventRowView(event: $0)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var monthView: some View {
        let selectedDay = selection.selectedDay
        let dayTimeline = TimelineBuilder.build(events: appState.agenda, day: selectedDay)
        return VStack(spacing: 0) {
            MonthGridView(events: appState.agenda, anchor: anchor, selectedDay: $selection.selectedDay)
                .padding(.vertical, 8)
            Divider()
            HStack {
                Text(selectedDay, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            if dayTimeline.isEmpty {
                Text(L10n.text("popover.noMeetings")).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(dayTimeline.allDay + dayTimeline.hourGroups.flatMap(\.events)) {
                            EventRowView(event: $0)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(L10n.text("app.name")).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button(L10n.text("common.workspace")) { WorkspaceWindowController.shared.show() }.buttonStyle(.borderless).font(.caption)
            Button(L10n.text("common.quit")) { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Navigation

    private var periodLabel: String {
        if mode == .month { return anchor.formatted(.dateTime.month(.wide).year()) }
        let start = weekInterval.start
        let end = cal.date(byAdding: .day, value: 6, to: start)!
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func shift(_ direction: Int) {
        if mode == .week { selection.shiftWeek(direction, calendar: cal) }
        else { selection.shiftMonth(direction, calendar: cal) }
    }

    private func goToToday() {
        selection.resetToToday(calendar: cal)
    }

    private func syncVisiblePeriod() {
        guard mode != .day, !DebugFixtures.isActive else { return }
        let interval = visibleInterval
        let key = "\(mode.rawValue)|\(Int(interval.start.timeIntervalSince1970))"
        guard !syncedPeriods.contains(key) else { return }
        syncedPeriods.insert(key)
        Task { await SyncCoordinator.shared.syncRange(interval.start, interval.end) }
    }

    private func syncError(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.caption).lineLimit(2)
            Spacer()
            Button(L10n.text("common.retry")) { Task { await SyncCoordinator.shared.syncAll() } }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }
}
