import SwiftUI

/// A month calendar grid: weekday header + 6×7 day cells with meeting dots.
/// Tapping a day updates `selectedDay`.
struct MonthGridView: View {
    let events: [UnifiedEvent]
    let anchor: Date                 // any date within the month to display
    @Binding var selectedDay: Date

    private var cal: Calendar {
        var c = Calendar.current; c.timeZone = .current; return c
    }

    /// 6 weeks × 7 days starting at the first weekday on/before the 1st.
    private var gridDays: [Date] {
        let monthStart = cal.dateInterval(of: .month, for: anchor)?.start ?? cal.startOfDay(for: anchor)
        let weekday = cal.component(.weekday, from: monthStart)             // 1…7
        let offset = (weekday - cal.firstWeekday + 7) % 7
        let gridStart = cal.date(byAdding: .day, value: -offset, to: monthStart)!
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var weekdaySymbols: [String] {
        let syms = cal.veryShortStandaloneWeekdaySymbols     // ["S","M",...]
        let start = cal.firstWeekday - 1
        return (0..<7).map { syms[($0 + start) % 7] }
    }

    private func count(_ day: Date) -> Int {
        events.filter { e in
            guard e.status != "cancelled" else { return false }
            if e.isAllDay { return cal.isDate(e.startTs, inSameDayAs: day) }
            let dayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day))!
            return e.startTs < dayEnd && e.endTs > cal.startOfDay(for: day)
        }.count
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { s in
                    Text(s).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(gridDays, id: \.timeIntervalSince1970) { day in
                    cell(day)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    private func cell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: anchor, toGranularity: .month)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let n = count(day)
        return Button {
            selectedDay = cal.startOfDay(for: day)
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(inMonth ? .primary : .tertiary)
                Circle()
                    .fill(n > 0 ? Color.accentColor : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isToday ? Color.accentColor : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(n > 0 ? "\(n) meeting\(n == 1 ? "" : "s")" : "")
    }
}
