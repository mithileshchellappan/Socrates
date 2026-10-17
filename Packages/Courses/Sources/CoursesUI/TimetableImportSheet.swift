import Courses
import StudyCore
import StudyUI
import SwiftUI

/// The confirm sheet of a timetable drop (docs/DESIGN.md §8.3): per course what the files add —
/// weekly slots ("Wed 16:00–18:00 · Room 104 · weekly"), one-off sessions and exam dates. Courses in
/// the library are in; courses that are not have a checkbox and are added only when checked. The
/// semester's widened breaks last. Import is the one filled button; Cancel changes nothing.
public struct TimetableImportSheet: View {
    private let proposal: TimetableImport
    private let onImport: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var included: Set<UUID>

    /// - Parameter onImport: the new courses the student checked.
    public init(proposal: TimetableImport, onImport: @escaping (Set<UUID>) -> Void) {
        self.proposal = proposal
        self.onImport = onImport
        _included = State(initialValue: proposal.defaultIncluded)
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    ForEach(proposal.courses) { course in
                        Section {
                            rows(of: course)
                        }
                    }
                    if proposal.semesterChanged {
                        Section(proposal.semester.name) {
                            semesterRows
                        }
                    }
                }
                .formStyle(.grouped)
                #if os(macOS)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import", action: confirm)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canImport)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                #endif
            }
            .navigationTitle("Import Timetable")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: confirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canImport)
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 620)
        #endif
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(of course: TimetableCourse) -> some View {
        header(course)
        if !course.isNew || included.contains(course.id) {
            ForEach(course.slots) { slot in
                row(slot.kind.displayName, slotLine(slot), help: slot.location)
            }
            ForEach(course.sessions) { session in
                row(session.kind.displayName, dateLine(session.startsAt, session.endsAt, zone: session.timeZone, rooms: [session.room]), help: session.location)
            }
            ForEach(course.items) { item in
                row(itemLabel(item), dateLine(item.startsAt, item.endsAt, zone: item.timeZone, rooms: item.rooms), help: item.room)
            }
        }
    }

    /// The course dot and name; a checkbox for a course the library does not have.
    @ViewBuilder
    private func header(_ course: TimetableCourse) -> some View {
        let label = HStack(spacing: 8) {
            CourseDot(hex: proposal.colorHex(for: course.id, including: included), size: 9)
            Text(course.name)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        if course.isNew {
            Toggle(isOn: inclusion(of: course.id)) { label }
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
        } else {
            label
        }
    }

    private func row(_ label: String, _ line: Text, help: String) -> some View {
        LabeledContent {
            line
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } label: {
            Text(label)
        }
        .help(help)
    }

    @ViewBuilder
    private var semesterRows: some View {
        let semester = proposal.semester
        if proposal.semesterIsNew || proposal.periodChanged {
            LabeledContent("Lectures") {
                Text(dayRange(semester.lectureStart, semester.lectureEnd, zone: semester.zone))
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(proposal.changedBreaks, id: \.self) { semesterBreak in
            LabeledContent(semesterBreak.name) {
                Text(dayRange(semesterBreak.first, semesterBreak.last, zone: semester.zone))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Words

    /// "Wed 16:00–18:00 · Room 104 · weekly".
    private func slotLine(_ slot: TimetableSlot) -> Text {
        let text = SessionText(locale: locale, timeZone: TimeZone(identifier: slot.timeZone) ?? .current)
        let cadence = switch slot.weekInterval {
        case 1: String(localized: "weekly")
        case 2: String(localized: "every 2 weeks")
        default: String(localized: "every \(slot.weekInterval) weeks")
        }
        return line(lead: text.shortWeekday(slot.weekday), time: SessionText.minutes(slot.startMinute, slot.endMinute), rest: [slot.room, cadence])
    }

    /// "Tue 9 Feb, 10:00–12:00 · Room 102 / Hall A".
    private func dateLine(_ start: Date, _ end: Date, zone: String, rooms: [String]) -> Text {
        let text = SessionText(locale: locale, timeZone: TimeZone(identifier: zone) ?? .current)
        return line(lead: "\(text.day(start)),", time: text.timeRange(start, end), rest: [rooms.filter { !$0.isEmpty }.joined(separator: " / ")])
    }

    /// The lead, the time in SF Mono, then the other facts after " · ".
    private func line(lead: String, time: String, rest: [String]) -> Text {
        var text = Text("\(lead) \(Text(time).font(.mono(12)))")
        for part in rest where !part.isEmpty {
            text = Text("\(text) · \(part)")
        }
        return text
    }

    private func itemLabel(_ item: TimetableItem) -> String {
        guard item.kind == .exam else { return String(localized: "Exam review") }
        return switch item.attempt {
        case ...1: String(localized: "Exam")
        case 2: String(localized: "Exam (2nd date)")
        case 3: String(localized: "Exam (3rd date)")
        default: String(localized: "Exam (\(item.attempt)th date)")
        }
    }

    /// "Thu 24 Dec – Wed 6 Jan".
    private func dayRange(_ first: CalendarDay, _ last: CalendarDay, zone: TimeZone) -> String {
        let text = SessionText(locale: locale, timeZone: zone)
        return "\(text.day(first.start(in: zone))) – \(text.day(last.start(in: zone)))"
    }

    // MARK: - Actions

    private var canImport: Bool {
        proposal.courses.contains { !$0.isNew || included.contains($0.id) }
    }

    private func inclusion(of courseID: UUID) -> Binding<Bool> {
        Binding(
            get: { included.contains(courseID) },
            set: { isOn in
                if isOn { included.insert(courseID) } else { included.remove(courseID) }
            }
        )
    }

    private func confirm() {
        guard canImport else { return }
        onImport(included)
        dismiss()
    }
}
