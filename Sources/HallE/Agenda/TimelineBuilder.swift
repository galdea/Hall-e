import Foundation

/// Pure transform: unified events + "now" → the agenda sections the popover shows
/// for a given day (defaults to today). No I/O, fully unit-tested.
struct AgendaTimeline {
    var day: Date
    var allDay: [UnifiedEvent]
    var inProgress: [UnifiedEvent]     // start ≤ now < end (timed)
    var next: UnifiedEvent?            // soonest upcoming (timed, start > now)
    var hourGroups: [HourGroup]        // all timed events for the day, grouped by start hour
    var isEmpty: Bool { allDay.isEmpty && hourGroups.isEmpty }

    struct HourGroup: Identifiable {
        var hour: Date            // top of the hour, local
        var events: [UnifiedEvent]
        var id: TimeInterval { hour.timeIntervalSince1970 }
    }
}

enum AgendaScope: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }
    var label: String { self == .week ? "Week" : "Month" }
}

enum TimelineBuilder {
    /// Build the agenda sections for a specific day (defaults to `now`'s day).
    /// `now` is used only for the in-progress / next highlighting.
    static func build(events: [UnifiedEvent], day: Date? = nil, now: Date = Date(),
                      calendar: Calendar = .current, includeCancelled: Bool = false) -> AgendaTimeline {
        var cal = calendar
        cal.timeZone = .current
        let refDay = day ?? now
        let dayStart = cal.startOfDay(for: refDay)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        let dayEvents = events.filter { e in
            guard includeCancelled || e.status != "cancelled" else { return false }
            if e.isAllDay {
                return cal.isDate(e.startTs, inSameDayAs: refDay)
            }
            return e.startTs < dayEnd && e.endTs > dayStart
        }

        let allDay = dayEvents.filter { $0.isAllDay }.sorted { $0.title < $1.title }
        let timed = dayEvents.filter { !$0.isAllDay }.sorted { $0.startTs < $1.startTs }

        let inProgress = timed.filter { $0.startTs <= now && now < $0.endTs }
        let next = timed.first { $0.startTs > now }

        var groups: [Date: [UnifiedEvent]] = [:]
        for e in timed {
            let hour = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: e.startTs))!
            groups[hour, default: []].append(e)
        }
        let hourGroups = groups.keys.sorted().map { hour in
            AgendaTimeline.HourGroup(hour: hour, events: groups[hour]!.sorted { $0.startTs < $1.startTs })
        }

        return AgendaTimeline(day: dayStart, allDay: allDay, inProgress: inProgress,
                              next: next, hourGroups: hourGroups)
    }

    /// The calendar interval (week or month) that contains `anchor`.
    static func periodInterval(scope: AgendaScope, anchor: Date, calendar: Calendar = .current) -> DateInterval {
        var cal = calendar
        cal.timeZone = .current
        let component: Calendar.Component = scope == .week ? .weekOfYear : .month
        return cal.dateInterval(of: component, for: anchor)
            ?? DateInterval(start: cal.startOfDay(for: anchor), duration: 86_400)
    }

    struct DaySummary: Identifiable, Equatable {
        let day: Date
        let count: Int
        var id: TimeInterval { day.timeIntervalSince1970 }
    }

    /// One entry per day in `interval`, with its (non-cancelled) meeting count.
    static func daySummaries(in interval: DateInterval, events: [UnifiedEvent],
                             calendar: Calendar = .current) -> [DaySummary] {
        var cal = calendar
        cal.timeZone = .current
        var result: [DaySummary] = []
        var day = cal.startOfDay(for: interval.start)
        while day < interval.end {
            let dayEnd = cal.date(byAdding: .day, value: 1, to: day)!
            let count = events.filter { e in
                guard e.status != "cancelled" else { return false }
                if e.isAllDay { return cal.isDate(e.startTs, inSameDayAs: day) }
                return e.startTs < dayEnd && e.endTs > day
            }.count
            result.append(DaySummary(day: day, count: count))
            day = dayEnd
        }
        return result
    }
}
