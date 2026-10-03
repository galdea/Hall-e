#if DEBUG
import AppKit
import SwiftUI

/// A dedicated launch path with no database, recording service, timers, OAuth or provider jobs.
@MainActor enum CalendarPreview {
    private static var window: NSWindow?
    /// Offscreen fixture render for visual review when native automation is unavailable.
    static func renderIfRequested() -> Bool {
        guard let directory = ProcessInfo.processInfo.environment["HALLE_DEBUG_CALENDAR_RENDER_DIR"] else { return false }
        do {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try render(CalendarPreviewContent(), size: CGSize(width: 1000, height: 800),
                       to: url.appendingPathComponent("calendar-fixture.png"))
            let draft = CalendarEventDraft(title: "Project review", start: Date(timeIntervalSince1970: 1791205200),
                end: Date(timeIntervalSince1970: 1791208800), timeZoneID: "America/Santiago")
            let target = CalendarWriteTarget(CalendarSource(accountEmail: "preview@example.invalid", calendarId: "preview",
                summary: "Preview calendar (mock)", colorHex: nil, isPrimary: true, accessRole: "owner", isSelected: true))
            try render(CalendarEventEditor(draft: draft, targets: [target], writableAccounts: [target.accountEmail],
                onEnableWriting: { _ in }, onSave: { _, _ in }), size: CGSize(width: 550, height: 650),
                to: url.appendingPathComponent("calendar-editor-fixture.png"))
            FileHandle.standardOutput.write(Data("Calendar fixture rendered offscreen. No native interaction verification.\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }

    private static func render<Content: View>(_ view: Content, size: CGSize, to url: URL) throws {
        let content = view.frame(width: size.width, height: size.height).background(Color.white)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_US"))
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Render only our own offscreen view; no desktop screenshot or UI input.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CalendarCreationError.validation("AppKit could not allocate the fixture render.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CalendarCreationError.validation("AppKit could not encode the fixture render.")
        }
        try png.write(to: url, options: .atomic)
        window.close()
    }

    static func showIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["HALLE_DEBUG_CALENDAR_PREVIEW"] == "1" else { return false }
        if let window { window.makeKeyAndOrderFront(nil); return true }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Hall-E Calendar Preview · isolated fixtures"
        window.contentView = NSHostingView(rootView: CalendarPreviewContent())
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        self.window = window
        return true
    }
}

private struct CalendarPreviewContent: View {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "America/Santiago")!; return value
    }
    @State private var month = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
    @State private var selected = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
    @State private var editing = false
    @State private var detail: UnifiedEvent?
    @State private var saved: [UnifiedEvent] = []
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }
    private var events: [UnifiedEvent] {
        let routine = (1...31).filter { day in
            let weekday = calendar.component(.weekday, from: date(day))
            return [2, 4, 5].contains(weekday) && ![7, 12].contains(day)
        }.map { event("class-\($0)", "Class A / B", day: $0, hour: 14, routine: true) }
        return routine + [event("client", "Project review", day: 5, hour: 10), event("personal", "Personal appointment", day: 9, hour: 9)] + saved
    }
    private func event(_ id: String, _ title: String, day: Int, hour: Int, routine: Bool = false) -> UnifiedEvent {
        UnifiedEvent(dedupKey: id, title: title, startTs: date(day, hour), endTs: date(day, hour + 1),
            isAllDay: false, status: "confirmed", effectiveResponse: "accepted", meetingURL: nil,
            location: nil, descriptionText: nil, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil,
            iCalUID: nil, winnerAccountEmail: "preview@example.invalid", projectId: nil, projectConfidence: nil,
            sourcesJSON: "[]", recurrenceRulesJSON: routine ? "[\"RRULE:FREQ=WEEKLY;BYDAY=MO,WE,TH\"]" : nil)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer(); Text(month, format: .dateTime.month(.wide).year()).font(.title2)
                Spacer(); Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }.padding(.horizontal, 20).padding(.top, 16)
            CalendarView(events: events, month: $month, selectedDay: $selected, calendar: calendar,
                annotations: [date(7): "No Class A / B classes · local context", date(12): "No Class A / B classes · holiday · local context"],
                onSelect: { detail = $0 }, onAdd: { selected = $0; editing = true })
        }
        .environment(\.timeZone, calendar.timeZone)
        .sheet(item: $detail) { event in
            VStack(alignment: .leading, spacing: 12) {
                Text(event.title).font(.title2)
                Text(event.startTs, format: .dateTime.day().month().hour().minute())
                Text("Isolated fixture · no external calendar")
                Button("Close") { detail = nil }
            }.padding(28).frame(width: 400)
        }
        .sheet(isPresented: $editing) {
            CalendarEventEditor(draft: CalendarEventDraft(start: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selected)!,
                end: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: selected)!, timeZoneID: calendar.timeZone.identifier),
                targets: [CalendarWriteTarget(CalendarSource(accountEmail: "preview@example.invalid", calendarId: "preview", summary: "Preview calendar (mock)", colorHex: nil, isPrimary: true, accessRole: "owner", isSelected: true))],
                writableAccounts: ["preview@example.invalid"], onEnableWriting: { _ in },
                onSave: { draft, _ in
                    saved.append(UnifiedEvent(dedupKey: draft.providerID, title: draft.title, startTs: draft.start, endTs: draft.end,
                        isAllDay: draft.allDay, status: "confirmed", effectiveResponse: nil, meetingURL: nil, location: nil,
                        descriptionText: draft.notes, htmlLink: nil, organizerEmail: nil, attendeesJSON: nil, iCalUID: nil,
                        winnerAccountEmail: "preview@example.invalid", projectId: nil, projectConfidence: nil, sourcesJSON: "[]",
                        recurrenceRulesJSON: String(decoding: try JSONEncoder().encode(draft.rules), as: UTF8.self)))
                })
        }
    }
    private func shift(_ value: Int) { month = calendar.date(byAdding: .month, value: value, to: month)! }
}
#endif
