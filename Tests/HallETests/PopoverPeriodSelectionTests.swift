import Testing
import Foundation
@testable import HallE

@Suite("Popover period selection")
struct PopoverPeriodSelectionTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Santiago") ?? .gmt
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Hall-e stays in the menu bar for days; the popover keeps its SwiftUI
    /// state the whole time, so reopening it must land on the current day.
    @Test func resetSelectsTodayAfterTheAppHasRunForDays() {
        let launchDay = date(2026, 8, 1)
        var selection = PopoverPeriodSelection(now: launchDay, calendar: calendar)
        let today = date(2026, 8, 4, 19)

        selection.resetToToday(now: today, calendar: calendar)

        #expect(selection.selectedDay == calendar.startOfDay(for: today))
        #expect(calendar.isDate(selection.anchor, inSameDayAs: today))
    }

    /// Leaving the Month tab on a browsed month and coming back resets both the
    /// grid's month and the selected day.
    @Test func resetReturnsFromABrowsedMonth() {
        let today = date(2026, 8, 4)
        var selection = PopoverPeriodSelection(now: today, calendar: calendar)
        selection.shiftMonth(2, calendar: calendar)
        #expect(calendar.component(.month, from: selection.anchor) == 10)
        #expect(selection.selectedDay == date(2026, 10, 1, 0))

        selection.resetToToday(now: today, calendar: calendar)

        #expect(calendar.component(.month, from: selection.anchor) == 8)
        #expect(selection.selectedDay == calendar.startOfDay(for: today))
    }

    @Test func resetIsIdempotentOnTheCurrentDay() {
        let today = date(2026, 8, 4, 9)
        var selection = PopoverPeriodSelection(now: today, calendar: calendar)
        let before = selection

        selection.resetToToday(now: date(2026, 8, 4, 23), calendar: calendar)

        #expect(selection == before)
    }

    @Test func weekShiftMovesTheAnchorByWholeWeeks() {
        var selection = PopoverPeriodSelection(now: date(2026, 8, 4), calendar: calendar)
        selection.shiftWeek(-1, calendar: calendar)
        #expect(calendar.isDate(selection.anchor, inSameDayAs: date(2026, 7, 28)))
    }
}
