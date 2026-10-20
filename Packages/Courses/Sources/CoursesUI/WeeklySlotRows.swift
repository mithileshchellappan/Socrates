import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Column widths of the weekly slots table (mockup 08).
enum SlotColumns {
    static let kind: CGFloat = 70
    static let day: CGFloat = 38
    static let time: CGFloat = 104
    static let more: CGFloat = 18
    static let spacing: CGFloat = 8
}

/// Type, Day, Time, Room: 11 pt tertiary in a 24 pt row.
struct SlotHeaderRow: View {
    var body: some View {
        HStack(spacing: SlotColumns.spacing) {
            Text("Type").frame(width: SlotColumns.kind, alignment: .leading)
            Text("Day").frame(width: SlotColumns.day, alignment: .leading)
            Text("Time").frame(width: SlotColumns.time, alignment: .leading)
            Text("Room").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: SlotColumns.more, height: 1)
        }
        .font(.subheadline)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}

/// One weekly slot, edited in place: type and day menus, the time opens a popover, the room is a
/// plain field, more actions behind the trailing ellipsis. The hovered row is filled.
struct SlotRow: View {
    let slot: WeeklySlot
    let text: SessionText
    let save: (WeeklySlot) -> Void
    let delete: (WeeklySlot.ID) -> Void
    var editsTimeInitially = false

    @State private var room = ""
    @State private var editsTime = false
    @State private var isHovered = false
    @FocusState private var roomFocused: Bool

    var body: some View {
        HStack(spacing: SlotColumns.spacing) {
            PlainMenu(title: slot.kind.displayName) {
                ForEach(SessionKind.slotKinds, id: \.self) { kind in
                    Button(kind.displayName) { update { $0.kind = kind } }
                }
            }
            .frame(width: SlotColumns.kind, alignment: .leading)
            .accessibilityLabel(Text("Type"))

            PlainMenu(title: text.shortWeekday(slot.weekday)) {
                ForEach(1...7, id: \.self) { weekday in
                    Button(text.weekdayName(weekday)) { update { $0.weekday = weekday } }
                }
            }
            .frame(width: SlotColumns.day, alignment: .leading)
            .accessibilityLabel(Text("Day"))

            Button {
                editsTime = true
            } label: {
                HStack(spacing: 4) {
                    Text(SessionText.minutes(slot.startMinute, slot.endMinute))
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                    if slot.weekInterval > 1 {
                        Image(systemName: "2.circle")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Every other week"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: SlotColumns.time, alignment: .leading)
            .popover(isPresented: $editsTime, arrowEdge: .bottom) {
                SlotTimeEditor(slot: slot, save: save)
            }
            .accessibilityLabel(Text("Time"))

            // The prompt drawn here in tertiary, as the column header and the ghost row: a Mac
            // field's own placeholder ignores its style.
            TextField("Room", text: $room, prompt: Text(verbatim: ""))
                .labelsHidden()
                .textFieldStyle(.plain)
                // A long room ("B3-1020, Example Road 3") ends in … in a narrow column.
                .truncationMode(.tail)
                .background(alignment: .leading) {
                    if room.isEmpty {
                        Text("Add room")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused($roomFocused)
                .onSubmit(commitRoom)
                .onChange(of: roomFocused) {
                    if !roomFocused { commitRoom() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Toggle("Every Other Week", isOn: Binding(
                    get: { slot.weekInterval > 1 },
                    set: { everyOther in update { $0.weekInterval = everyOther ? 2 : 1 } }
                ))
                Divider()
                Button("Delete Slot", role: .destructive) { delete(slot.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: SlotColumns.more, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: SlotColumns.more)
            .opacity(isHovered || roomFocused ? 1 : 0)
            .accessibilityLabel(Text("More"))
        }
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onAppear {
            room = slot.room
            if editsTimeInitially { editsTime = true }
        }
        .onChange(of: slot.room) {
            if !roomFocused { room = slot.room }
        }
        .contextMenu {
            Button("Delete Slot", role: .destructive) { delete(slot.id) }
        }
    }

    private func update(_ change: (inout WeeklySlot) -> Void) {
        var changed = slot
        change(&changed)
        if changed != slot { save(changed) }
    }

    private func commitRoom() {
        let typed = room
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        update { $0.room = trimmed }
        guard trimmed != typed else { return }
        // The field's own text is trimmed after AppKit has finished the key that committed it.
        Task { @MainActor in
            if room == typed { room = trimmed }
        }
    }
}

/// The table's row while the course has no slots, in tertiary: the slot its one-off sessions
/// suggest ("Seminar Wed 16:15–17:45"), or dashes. Clicking it adds the slot.
struct GhostSlotRow: View {
    let guess: WeeklySlot?
    let text: SessionText
    let add: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: add) {
            HStack(spacing: SlotColumns.spacing) {
                Text(guess?.kind.displayName ?? "–")
                    .frame(width: SlotColumns.kind, alignment: .leading)
                Text(guess.map { text.shortWeekday($0.weekday) } ?? "–")
                    .frame(width: SlotColumns.day, alignment: .leading)
                Text(guess.map { SessionText.minutes($0.startMinute, $0.endMinute) } ?? "–:––")
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: SlotColumns.time, alignment: .leading)
                Text(guess.map { $0.room.isEmpty ? String(localized: "Add room") : $0.room } ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus")
                    .frame(width: SlotColumns.more)
                    .opacity(isHovered ? 1 : 0)
            }
            .lineLimit(1)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .frame(height: 31)
            .background(isHovered ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text("Add Slot"))
    }
}

/// Start, end, repetition and validity of a slot. Saves once, when the popover closes.
struct SlotTimeEditor: View {
    let original: WeeklySlot
    let save: (WeeklySlot) -> Void
    @State private var slot: WeeklySlot

    init(slot: WeeklySlot, save: @escaping (WeeklySlot) -> Void) {
        original = slot
        self.save = save
        _slot = State(initialValue: slot)
    }

    var body: some View {
        Form {
            DatePicker("Starts", selection: start, displayedComponents: .hourAndMinute)
            DatePicker("Ends", selection: end, displayedComponents: .hourAndMinute)
            Picker("Repeat", selection: $slot.weekInterval) {
                Text("Every Week").tag(1)
                Text("Every Other Week").tag(2)
            }
            LabeledContent("From") {
                OptionalDayPicker(day: $slot.validFrom)
            }
            LabeledContent("Until") {
                OptionalDayPicker(day: $slot.validUntil)
            }
        }
        .formStyle(.grouped)
        .environment(\.timeZone, .gmt)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear {
            if slot != original { save(slot) }
        }
    }

    private var start: Binding<Date> {
        Binding(
            get: { MinuteClock.date(slot.startMinute) },
            set: { date in
                slot.startMinute = MinuteClock.minute(date)
            }
        )
    }

    private var end: Binding<Date> {
        Binding(
            get: { MinuteClock.date(slot.endMinute % 1440) },
            set: { date in
                var minutes = MinuteClock.minute(date) - slot.startMinute
                if minutes <= 0 { minutes += 1440 }
                slot.durationMinutes = minutes
            }
        )
    }
}

/// A day that may be unset: a checkbox, and the date when it is set.
struct OptionalDayPicker: View {
    @Binding var day: CalendarDay?
    var fallback = CalendarDay(Date(), in: .gmt)

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Set", isOn: Binding(
                get: { day != nil },
                set: { day = $0 ? (day ?? fallback) : nil }
            ))
            .labelsHidden()
            if day != nil {
                DatePicker("Day", selection: Binding(
                    get: { DayClock.date(day ?? fallback) },
                    set: { day = DayClock.day($0) }
                ), displayedComponents: .date)
                .labelsHidden()
            }
        }
    }
}
