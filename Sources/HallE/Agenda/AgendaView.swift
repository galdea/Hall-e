import SwiftUI

struct AgendaView: View {
    let events: [UnifiedEvent]
    let hasAccounts: Bool
    var day: Date? = nil

    private var isToday: Bool {
        guard let day else { return true }
        return Calendar.current.isDateInToday(day)
    }
    private var timeline: AgendaTimeline {
        TimelineBuilder.build(events: events, day: day)
    }

    var body: some View {
        if !hasAccounts {
            emptyState(
                icon: "person.crop.circle.badge.plus",
                title: "No accounts yet",
                message: "Connect a Google account in Settings to see your day here."
            )
        } else if timeline.isEmpty {
            emptyState(
                icon: "sparkles",
                title: "Nothing scheduled",
                message: isToday ? "Enjoy the open time." : "No meetings on this day."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !timeline.allDay.isEmpty { allDaySection }
                    if isToday, let next = timeline.next, timeline.inProgress.isEmpty {
                        nextSection(next)
                    }
                    timelineSection
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var allDaySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("All-day")
            ForEach(timeline.allDay) { EventRowView(event: $0) }
        }
    }

    private func nextSection(_ event: UnifiedEvent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Next")
            EventRowView(event: event)
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(isToday ? "Today" : "Schedule")
            ForEach(timeline.hourGroups) { group in
                HStack(alignment: .top, spacing: 8) {
                    Text(group.hour, format: .dateTime.hour())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 34, alignment: .trailing)
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(group.events) { EventRowView(event: $0) }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        }
        .frame(maxHeight: .infinity)
    }
}
