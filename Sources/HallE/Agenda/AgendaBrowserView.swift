import SwiftUI

/// Week/month agenda browser: a sidebar of the period's days (with meeting
/// counts) and a detail pane showing the selected day's meetings. Navigating a
/// period fetches it on demand via SyncCoordinator.
struct AgendaBrowserView: View {
    @State private var appState = AppState.shared
    @State private var scope: AgendaScope = .week
    @State private var anchor = Date()          // a date within the shown period
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var syncedPeriods = Set<String>()

    private var interval: DateInterval {
        TimelineBuilder.periodInterval(scope: scope, anchor: anchor)
    }
    private var summaries: [TimelineBuilder.DaySummary] {
        TimelineBuilder.daySummaries(in: interval, events: appState.agenda)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            dayDetail
        }
        .onAppear { syncVisiblePeriod() }
        .onChange(of: scope) { _, _ in clampSelectionAndSync() }
        .onChange(of: anchor) { _, _ in clampSelectionAndSync() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(summaries, selection: Binding(
                get: { selectedDay },
                set: { if let d = $0 { selectedDay = d } }
            )) { summary in
                dayRow(summary).tag(summary.day)
            }
            .listStyle(.sidebar)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Picker("", selection: $scope) {
                ForEach(AgendaScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
                Button("Today") { anchor = Date(); selectedDay = Calendar.current.startOfDay(for: Date()) }
                    .buttonStyle(.link).font(.caption)
                Spacer()
                if appState.isSyncing { ProgressView().controlSize(.mini) }
            }
        }
        .padding(10)
    }

    private func dayRow(_ summary: TimelineBuilder.DaySummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.day, format: .dateTime.weekday(.abbreviated))
                    .font(.caption).foregroundStyle(isToday(summary.day) ? Color.accentColor : .secondary)
                Text(summary.day, format: .dateTime.day().month(.abbreviated))
                    .font(.callout)
            }
            Spacer()
            if summary.count > 0 {
                Text("\(summary.count)")
                    .font(.caption2).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Detail

    private var dayDetail: some View {
        let timeline = TimelineBuilder.build(events: appState.agenda, day: selectedDay)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedDay, format: .dateTime.weekday(.wide).day().month(.wide).year())
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if timeline.isEmpty {
                ContentUnavailableView("No meetings", systemImage: "calendar",
                                       description: Text("Nothing scheduled on this day."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !timeline.allDay.isEmpty {
                            sectionLabel("All-day")
                            ForEach(timeline.allDay) { EventRowView(event: $0) }
                        }
                        if !timeline.hourGroups.isEmpty {
                            sectionLabel("Timed")
                            ForEach(timeline.hourGroups) { group in
                                ForEach(group.events) { EventRowView(event: $0) }
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 4)
    }

    // MARK: - Navigation

    private var periodLabel: String {
        if scope == .month {
            return anchor.formatted(.dateTime.month(.wide).year())
        }
        let end = Calendar.current.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
        let start = interval.start
        return "\(start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func isToday(_ d: Date) -> Bool { Calendar.current.isDateInToday(d) }

    private func shift(_ direction: Int) {
        let comp: Calendar.Component = scope == .week ? .weekOfYear : .month
        if let d = Calendar.current.date(byAdding: comp, value: direction, to: anchor) { anchor = d }
    }

    /// Keep the selected day inside the shown period and fetch that period.
    private func clampSelectionAndSync() {
        if !interval.contains(selectedDay) {
            selectedDay = Calendar.current.startOfDay(for: interval.start)
        }
        syncVisiblePeriod()
    }

    /// Fetch the visible period on demand (once per period).
    private func syncVisiblePeriod() {
        guard !DebugFixtures.isActive else { return }  // don't rebuild away sample data
        let key = "\(scope.rawValue)|\(Int(interval.start.timeIntervalSince1970))"
        guard !syncedPeriods.contains(key) else { return }
        syncedPeriods.insert(key)
        let (min, max) = (interval.start, interval.end)
        Task { await SyncCoordinator.shared.syncRange(min, max) }
    }
}
