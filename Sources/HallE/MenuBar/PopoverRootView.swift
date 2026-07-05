import SwiftUI

enum PopoverMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Root of the menu-bar popover: header, a Day / Week / Month switcher, and the
/// matching agenda content — all in one component.
struct PopoverRootView: View {
    @State private var appState = AppState.shared
    @State private var mode: PopoverMode = {
        ProcessInfo.processInfo.environment["HALLE_DEBUG_POPOVER_MODE"]
            .flatMap(PopoverMode.init(rawValue:)) ?? .day
    }()
    @State private var anchor = Date()                                   // reference date for week/month
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    @State private var syncedPeriods = Set<String>()

    private var cal: Calendar { var c = Calendar.current; c.timeZone = .current; return c }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeBar
            Divider()
            content
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 440, height: 600)
        .onChange(of: mode) { _, _ in syncVisiblePeriod() }
        .onChange(of: anchor) { _, _ in syncVisiblePeriod() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.headline)
                HStack(spacing: 5) {
                    Text(Date.now, style: .time)
                    if appState.isSyncing {
                        ProgressView().controlSize(.mini)
                    } else if let last = appState.lastSyncAt {
                        Text("· synced \(last.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await SyncCoordinator.shared.syncAll() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless).help("Refresh now").disabled(appState.isSyncing)
            Button { SettingsWindowController.shared.show() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless).help("Settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
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
                    Button("Today") { goToToday() }.buttonStyle(.link).font(.caption)
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
        let interval = TimelineBuilder.periodInterval(scope: .week, anchor: anchor)
        let days = TimelineBuilder.daySummaries(in: interval, events: appState.agenda).map(\.day)
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
        let dayTimeline = TimelineBuilder.build(events: appState.agenda, day: selectedDay)
        return VStack(spacing: 0) {
            MonthGridView(events: appState.agenda, anchor: anchor, selectedDay: $selectedDay)
                .padding(.vertical, 8)
            Divider()
            HStack {
                Text(selectedDay, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            if dayTimeline.isEmpty {
                Text("No meetings").font(.callout).foregroundStyle(.secondary)
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
            Text("Hall-e").font(.caption2).foregroundStyle(.tertiary)
            if let err = appState.lastSyncError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: - Navigation

    private var periodLabel: String {
        if mode == .month { return anchor.formatted(.dateTime.month(.wide).year()) }
        let interval = TimelineBuilder.periodInterval(scope: .week, anchor: anchor)
        let end = cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        return "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func shift(_ direction: Int) {
        let comp: Calendar.Component = mode == .week ? .weekOfYear : .month
        if let d = cal.date(byAdding: comp, value: direction, to: anchor) { anchor = d }
    }

    private func goToToday() {
        anchor = Date()
        selectedDay = cal.startOfDay(for: Date())
    }

    private func syncVisiblePeriod() {
        guard mode != .day, !DebugFixtures.isActive else { return }
        let scope: AgendaScope = mode == .week ? .week : .month
        let interval = TimelineBuilder.periodInterval(scope: scope, anchor: anchor)
        let key = "\(scope.rawValue)|\(Int(interval.start.timeIntervalSince1970))"
        guard !syncedPeriods.contains(key) else { return }
        syncedPeriods.insert(key)
        Task { await SyncCoordinator.shared.syncRange(interval.start, interval.end) }
    }
}
