import SwiftUI

struct AgendaView: View {
    let events: [UnifiedEvent]
    let hasAccounts: Bool
    var day: Date? = nil
    var showsHero = true
    var onSelect: ((UnifiedEvent) -> Void)?

    private var isToday: Bool { day.map(Calendar.current.isDateInToday) ?? true }
    private var timeline: AgendaTimeline { TimelineBuilder.build(events: events, day: day) }
    private var heroEvent: UnifiedEvent? {
        guard isToday, showsHero else { return nil }
        return timeline.inProgress.first ?? timeline.next
    }

    var body: some View {
        if !hasAccounts && events.isEmpty {
            HalleEmptyState(symbol: "person.crop.circle.badge.plus", title: L10n.text("agenda.noAccounts"),
                            detail: L10n.text("agenda.noAccounts.detail"))
        } else if timeline.isEmpty {
            HalleEmptyState(symbol: "sparkles", title: L10n.text("agenda.empty"),
                            detail: isToday ? L10n.text("agenda.empty.today") : L10n.text("agenda.empty.day"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let heroEvent { MeetingHeroCard(event: heroEvent, onSelect: onSelect) }
                    if !timeline.allDay.isEmpty { allDaySection }
                    timelineSection(excluding: heroEvent?.dedupKey)
                }.padding(12)
            }
        }
    }

    private var allDaySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(L10n.text("agenda.allDay"))
            ForEach(timeline.allDay) { EventRowView(event: $0, onSelect: onSelect) }
        }
    }

    private func timelineSection(excluding key: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(isToday ? L10n.text("agenda.today") : L10n.text("agenda.schedule"))
            ForEach(timeline.hourGroups) { group in
                let visible = group.events.filter { $0.dedupKey != key }
                if !visible.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { EventRowView(event: $0, onSelect: onSelect) }
                    }
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
    var onSelect: ((UnifiedEvent) -> Void)?

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
                        if let project = event.projectId { Text("·"); Text(project) }
                    }.font(.callout).foregroundStyle(.secondary)
                    MeetingActionButtons(event: event)
                }
            }
            .contentShape(Rectangle()).onTapGesture { onSelect?(event) }
        }
    }

    private func relativeText(now: Date) -> String {
        let target = event.startTs > now ? event.startTs : event.endTs
        return target.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}
