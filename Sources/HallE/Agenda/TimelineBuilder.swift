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

enum TimelineBuilder {
    static func build(events: [UnifiedEvent], now: Date = Date(),
                      calendar: Calendar = .current, includeCancelled: Bool = false) -> AgendaTimeline {
        var cal = calendar
        cal.timeZone = .current
        let dayStart = cal.startOfDay(for: now)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        let today = events.filter { e in
            guard includeCancelled || e.status != "cancelled" else { return false }
            if e.isAllDay {
                // All-day events overlap the day if their start is on this day.
                return cal.isDate(e.startTs, inSameDayAs: now)
            }
            return e.startTs < dayEnd && e.endTs > dayStart
        }

        let allDay = today.filter { $0.isAllDay }.sorted { $0.title < $1.title }
        let timed = today.filter { !$0.isAllDay }.sorted { $0.startTs < $1.startTs }

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
}
