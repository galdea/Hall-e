import SwiftUI

/// Shared by the production popover and the side-effect-free native preview.
struct CalendarView: View {
    let events: [UnifiedEvent]
    @Binding var month: Date
    @Binding var selectedDay: Date
    var calendar: Calendar = .current
    var annotations: [Date: String] = [:]
    var onSelect: (UnifiedEvent) -> Void
    var onAdd: (Date) -> Void

    private var days: [Date] { CalendarPresentation.days(in: month, calendar: calendar) }
    private var selectedEvents: [UnifiedEvent] { CalendarPresentation.events(on: selectedDay, events: events, calendar: calendar) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)
    var body: some View {
        GeometryReader { geometry in
            let cellHeight = max(44, min(80, (geometry.size.height - 245) / 6 - 5))
            VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label(PublicUICopy.text("Calendar", "Calendario"), systemImage: "calendar").font(.title2.weight(.semibold))
                Spacer()
                legend("circle.fill", PublicUICopy.text("Calendar event", "Evento de calendario"), .teal)
                legend("repeat", PublicUICopy.text("Daily / weekly", "Diario / semanal"), .indigo)
                Button { onAdd(selectedDay) } label: {
                    Label(PublicUICopy.text("Add event", "Añadir evento"), systemImage: "plus")
                }.buttonStyle(.borderedProminent)
            }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(0..<7, id: \.self) { offset in
                    let index = (offset + 1) % 7
                    Text(calendar.shortWeekdaySymbols[index].capitalized).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                ForEach(days, id: \.self) { day in dayCell(day, height: cellHeight) }
            }
            Divider()
            HStack {
                Text(selectedDay, format: .dateTime.weekday(.wide).day().month(.wide)).font(.headline)
                Spacer()
                Text(calendar.timeZone.identifier).font(.caption).foregroundStyle(.secondary)
            }
            if let note = annotations[calendar.startOfDay(for: selectedDay)] {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if selectedEvents.isEmpty {
                        Text(PublicUICopy.text("No visible events. This does not confirm availability.", "Sin eventos visibles. Esto no confirma disponibilidad."))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(selectedEvents) { event in
                        Button { onSelect(event) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: CalendarPresentation.routine(event.recurrenceRulesJSON) ? "repeat" : "calendar")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title).font(.callout.weight(.medium)).lineLimit(2)
                                    HStack {
                                        if event.isAllDay { Text(PublicUICopy.text("All day", "Todo el día")) }
                                        else { Text(event.startTs, style: .time); Text("–"); Text(event.endTs, style: .time) }
                                        if event.recurrenceException == true { Text(PublicUICopy.text("Modified occurrence", "Ocurrencia modificada")) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Text(event.sources.map(\.accountEmail).uniqued().joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(9).background(tint(event).opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 75, maxHeight: .infinity)
        }.padding(14)
        }
    }
    private func legend(_ symbol: String, _ title: String, _ color: Color) -> some View {
        Label(title, systemImage: symbol).font(.caption2).foregroundStyle(color)
    }
    private func tint(_ event: UnifiedEvent) -> Color { CalendarPresentation.routine(event.recurrenceRulesJSON) ? .indigo : .teal }
    private func dayCell(_ day: Date, height: CGFloat) -> some View {
        let daily = CalendarPresentation.events(on: day, events: events, calendar: calendar)
        let selected = calendar.isDate(day, inSameDayAs: selectedDay)
        let visibleCount = max(1, min(3, Int((height - 32) / 16)))
        let currentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        return Button { selectedDay = day } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("\(calendar.component(.day, from: day))").font(.callout.weight(.semibold))
                        .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : Color.primary)
                    Spacer()
                    if annotations[calendar.startOfDay(for: day)] != nil { Image(systemName: "info.circle").font(.caption2).foregroundStyle(.orange) }
                }
                ForEach(Array(daily.prefix(visibleCount))) { event in
                    HStack(spacing: 3) {
                        if CalendarPresentation.routine(event.recurrenceRulesJSON) { Image(systemName: "repeat").font(.system(size: 8)) }
                        if !event.isAllDay { Text(event.startTs, format: .dateTime.hour().minute()).monospacedDigit() }
                        Text(event.title).lineLimit(1)
                    }.font(.system(size: 9)).foregroundStyle(tint(event)).padding(.horizontal, 3).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tint(event).opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }
                if daily.count > visibleCount { Text("+\(daily.count - visibleCount)").font(.caption2).foregroundStyle(.secondary) }
                if daily.isEmpty { Text("—").font(.caption2).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
            }.padding(6).frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
                .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.14), lineWidth: selected ? 1.5 : 0.5))
                .opacity(currentMonth ? 1 : 0.42)
        }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

struct CalendarEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: CalendarEventDraft
    let targets: [CalendarWriteTarget]
    let writableAccounts: Set<String>
    var onEnableWriting: (CalendarWriteTarget) async throws -> Void
    var onSave: (CalendarEventDraft, CalendarWriteTarget) async throws -> Void
    @State private var targetID = ""
    @State private var busy = false
    @State private var error: String?
    @State private var frozenRequest = false
    @State private var permissionGranted = Set<String>()
    private var target: CalendarWriteTarget? { targets.first { $0.id == targetID } }
    private var canWrite: Bool { target.map { $0.writable && (writableAccounts.contains($0.accountEmail) || permissionGranted.contains($0.accountEmail)) } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PublicUICopy.text("New calendar event", "Nuevo evento de calendario")).font(.title2.weight(.semibold))
            Form {
                TextField(PublicUICopy.text("Title", "Título"), text: $draft.title)
                Picker(PublicUICopy.text("Calendar", "Calendario"), selection: $targetID) {
                    Text(PublicUICopy.text("Choose a calendar", "Elegir calendario")).tag("")
                    ForEach(targets) { item in Text("\(item.name) · \(item.accountEmail)\(item.writable ? "" : " (read only)")").tag(item.id).disabled(!item.writable) }
                }
                Toggle(PublicUICopy.text("All day", "Todo el día"), isOn: $draft.allDay)
                DatePicker(PublicUICopy.text("Start", "Inicio"), selection: $draft.start, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                DatePicker(PublicUICopy.text(draft.allDay ? "End date (exclusive)" : "End", draft.allDay ? "Fecha final (exclusiva)" : "Fin"), selection: $draft.end, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                TextField(PublicUICopy.text("Time zone", "Zona horaria"), text: $draft.timeZoneID)
                Picker(PublicUICopy.text("Repeat", "Repetir"), selection: $draft.repetition) {
                    Text(PublicUICopy.text("Does not repeat", "No se repite")).tag(CalendarEventDraft.Repetition.none)
                    Text(PublicUICopy.text("Daily", "Diariamente")).tag(CalendarEventDraft.Repetition.daily)
                    Text(PublicUICopy.text("Weekly", "Semanalmente")).tag(CalendarEventDraft.Repetition.weekly)
                }
                TextField(PublicUICopy.text("Notes", "Notas"), text: $draft.notes, axis: .vertical).lineLimit(2...4)
            }.disabled(busy || frozenRequest)
            if let target, !canWrite, target.writable {
                Button(PublicUICopy.text("Enable event writing…", "Permitir escritura de eventos…")) {
                    busy = true; error = nil
                    Task { do { try await onEnableWriting(target); permissionGranted.insert(target.accountEmail) }
                        catch { self.error = error.localizedDescription }; busy = false }
                }.disabled(busy || frozenRequest)
                Text(PublicUICopy.text("Opens the official account consent flow. No event is created until you save.", "Abre el consentimiento oficial de la cuenta. No se crea ningún evento hasta guardar."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let target, !target.isSelected {
                Text(PublicUICopy.text("This calendar is hidden from the agenda. The event will be saved there without changing your calendar selection.", "Este calendario está oculto en la agenda. El evento se guardará allí sin cambiar la selección de calendarios."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if targets.isEmpty { Text(PublicUICopy.text("Connect a calendar in Settings first.", "Primero conecta un calendario en Configuración.")) }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(PublicUICopy.text("Cancel", "Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(PublicUICopy.text(frozenRequest ? "Retry same save" : "Save to calendar", frozenRequest ? "Reintentar guardado" : "Guardar en calendario")) {
                    guard let target else { return }
                    do { draft = try draft.validated() } catch { self.error = error.localizedDescription; return }
                    busy = true; frozenRequest = true; error = nil
                    Task { do { try await onSave(draft, target); dismiss() }
                        catch { self.error = error.localizedDescription }; busy = false }
                }.buttonStyle(.borderedProminent).disabled(busy || !canWrite).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 550)
        .environment(\.timeZone, TimeZone(identifier: draft.timeZoneID) ?? .current)
    }
}
