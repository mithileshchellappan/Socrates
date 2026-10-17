import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Coming up (mockup 01): one dated list of sessions and items. A course bar marks a class or
/// event, an open ring something due; one grey gloss line at most; the sources behind one faint
/// glyph whose popover holds the calendar check and Undo. Hover: the quiet fill, the separators
/// beside the row hidden.
struct ComingUpSection: View {
    let entries: [ComingUpEntry]
    let courses: [Course.ID: Course]
    let now: Date
    let text: SessionText

    @Environment(\.deadlineActions) private var deadlineActions
    @Environment(\.studyServices) private var services
    @Environment(\.calendarMirror) private var mirror
    @State private var hoveredID: ComingUpEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coming up")
                .font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        // From the title's leading edge to the column's trailing edge; none
                        // beside the hovered row (its room is kept).
                        Hairline()
                            .padding(.leading, 32)
                            .padding(.trailing, 10)
                            .opacity(hoveredID == entry.id || hoveredID == entries[index - 1].id ? 0 : 1)
                    }
                    row(entry)
                        .onHover { inside in
                            if inside {
                                hoveredID = entry.id
                            } else if hoveredID == entry.id {
                                hoveredID = nil
                            }
                        }
                        .contextMenu { menu(entry) }
                }
            }
            .padding(.horizontal, -10)
        }
    }

    private func row(_ entry: ComingUpEntry) -> some View {
        let course = entry.courseID.flatMap { courses[$0] }
        let hovered = hoveredID == entry.id
        return CourseBarRow(
            color: .course(course),
            marker: entry.marker == .ring ? .ring : .bar,
            title: entry.title,
            gloss: entry.gloss,
            examStar: entry.isExamAdmission,
            day: text.day(entry.date),
            time: time(entry),
            dayNote: dayNote(entry),
            isStruck: entry.isCancelled,
            isHovered: hovered
        ) {
            SourceTrailButton(
                entries: entry.trail, now: now, inCalendar: entry.inCalendar, highlighted: hovered,
                undo: entry.undoSourceID.map { sourceID in
                    { @MainActor in run("Undo") { actions in try await actions.undo(sourceID) } }
                }
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel(entry, course: course)))
    }

    @ViewBuilder
    private func menu(_ entry: ComingUpEntry) -> some View {
        if let session = entry.session {
            if session.isCancelled {
                Button("Restore Session") { schedule.restore(session.id) }
            } else {
                Button("Cancel Session") { schedule.cancel(session.id) }
            }
        } else {
            let ids = entry.items.map(\.id)
            Button("Mark as Done") {
                run("Mark as Done") { actions in for id in ids { try await actions.complete(id) } }
            }
            let outside = entry.itemsOutsideCalendar.map(\.id)
            if !outside.isEmpty {
                Button("Add to Calendar") {
                    run("Add to Calendar") { actions in for id in outside { try await actions.addToCalendar(id) } }
                }
            }
            Divider()
            Button("Delete") {
                run("Delete") { actions in for id in ids { try await actions.remove(id) } }
            }
        }
    }

    /// A session's range, an item's due time; nothing for an all-day item.
    private func time(_ entry: ComingUpEntry) -> String? {
        if let end = entry.end { return text.timeRange(entry.date, end) }
        return entry.isAllDay ? nil : DayText.time(entry.date, timeZone: text.timeZone)
    }

    /// "and Fri 13 Nov" (12 pt text under the first day).
    private func dayNote(_ entry: ComingUpEntry) -> String? {
        switch entry.laterDays.count {
        case 0: nil
        case 1: String(localized: "and \(text.day(entry.laterDays[0]))")
        default: String(localized: "and \(entry.laterDays.count) more")
        }
    }

    private func accessibilityLabel(_ entry: ComingUpEntry, course: Course?) -> String {
        var parts = [course?.name ?? "", entry.title, text.day(entry.date)]
        if let time = time(entry) { parts.append(time) }
        if let note = dayNote(entry) { parts.append(note) }
        if let gloss = entry.gloss { parts.append(gloss) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var schedule: ScheduleActions { ScheduleActions(services: services, mirror: mirror) }

    /// Effects go through the app's `DeadlineActions`; failures are logged, the list follows the rows.
    private func run(_ label: String, _ work: @escaping @Sendable (DeadlineActions) async throws -> Void) {
        let actions = deadlineActions
        Task {
            do {
                try await work(actions)
            } catch {
                CoursesUILog.ui.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}

/// The mail line (mockup 01): 42 pt over a hairline, 8 pt closer to Coming up. It only counts:
/// what the course mail said is already in the rows.
struct TodayMailLine: View {
    let line: MailLine
    let courses: [Course.ID: Course]

    @Environment(\.openDestination) private var openDestination

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.system(size: 13))
                .frame(width: 15, height: 15)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            HStack(spacing: 7) {
                Text("\(line.unread) unread")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if !line.courses.isEmpty {
                    Text(verbatim: "·")
                    HStack(spacing: 10) {
                        ForEach(line.courses, id: \.courseID) { count in
                            HStack(spacing: 4) {
                                CourseDot(course: courses[count.courseID], size: 7)
                                Text(count.count, format: .number)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("\(courses[count.courseID]?.name ?? ""): \(count.count)"))
                        }
                    }
                }
                if line.newsletters > 0 {
                    Text(newsletters)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                openDestination(.mail(.inbox, message: nil))
            } label: {
                Text("Open Mail")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .frame(minHeight: 42)
        .overlay(alignment: .top) {
            Hairline()
        }
        .padding(.top, -8)
    }

    private var newsletters: String {
        line.newsletters == 1
            ? String(localized: "· 1 newsletter")
            : String(localized: "· \(line.newsletters) newsletters")
    }
}
