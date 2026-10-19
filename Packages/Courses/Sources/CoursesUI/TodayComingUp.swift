import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI

/// Coming up (mockup 01): one dated list of sessions and items. A course bar marks a class or
/// event, an open ring something due; one grey gloss line at most; the sources behind one faint
/// glyph whose popover holds the calendar check and Undo. Hover: the quiet fill, the separators
/// beside the row hidden. M3.5: open tasks (ring) and mail that needs a reply ("Reply to …",
/// ring, the subject as its line, the faint envelope; a click opens the mail) follow the dated
/// rows with an empty right column.
struct ComingUpSection: View {
    let entries: [ComingUpEntry]
    let courses: [Course.ID: Course]
    let now: Date
    let text: SessionText
    /// M7: the iPhone's card of rows (mockup 16).
    var isPhone = false

    @Environment(\.deadlineActions) private var deadlineActions
    @Environment(\.studyServices) private var services
    @Environment(\.calendarMirror) private var mirror
    @Environment(\.openDestination) private var openDestination
    @State private var hoveredID: ComingUpEntry.ID?

    var body: some View {
        if isPhone {
            phoneBody
        } else {
            macBody
        }
    }

    /// The iPhone (mockup 16 `.t-sect`, `.card`, `.r`): "Coming up" (17 semibold) over one card
    /// (radius 20, the card surface, a 0.5 pt ring) of rows [10 pt marker | title 15 semibold over
    /// the gloss | the day (15) over the time (SF Mono 12.5)], hairlines from the title's edge.
    /// A tap opens a source popover or a reply's mail; a long press the row's menu.
    private var phoneBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coming up")
                .font(.headline)
                .tracking(-0.2)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Hairline()
                            .padding(.leading, 36)
                    }
                    phoneRow(entry)
                        .contextMenu { menu(entry) }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    @ViewBuilder
    private func phoneRow(_ entry: ComingUpEntry) -> some View {
        let course = entry.courseID.flatMap { courses[$0] }
        if let reply = entry.reply {
            PhoneComingUpRow(color: .course(course), isRing: true, title: entry.title, gloss: entry.gloss, day: "") {
                SourceGlyph(kinds: [.mail], highlighted: false)
            }
            .onTapGesture { open(reply) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityLabel(entry, course: course)))
            .accessibilityAddTraits(.isButton)
        } else {
            PhoneComingUpRow(
                color: .course(course),
                isRing: entry.marker == .ring,
                title: entry.title,
                gloss: entry.gloss,
                examStar: entry.isExamAdmission,
                day: entry.date.map(text.day) ?? "",
                time: time(entry),
                dayNote: dayNote(entry),
                isStruck: entry.isCancelled
            ) {
                SourceTrailButton(
                    entries: entry.trail, now: now, inCalendar: entry.inCalendar, highlighted: false,
                    undo: entry.undoSourceID.map { sourceID in
                        { @MainActor in run("Undo") { actions in try await actions.undo(sourceID) } }
                    }
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityLabel(entry, course: course)))
        }
    }

    private var macBody: some View {
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

    @ViewBuilder
    private func row(_ entry: ComingUpEntry) -> some View {
        let course = entry.courseID.flatMap { courses[$0] }
        let hovered = hoveredID == entry.id
        if let reply = entry.reply {
            CourseBarRow(
                color: .course(course), marker: .ring, title: entry.title, gloss: entry.gloss, day: "", isHovered: hovered
            ) {
                SourceGlyph(kinds: [.mail], highlighted: hovered)
            }
            .onTapGesture { open(reply) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityLabel(entry, course: course)))
            .accessibilityAddTraits(.isButton)
        } else {
            CourseBarRow(
                color: .course(course),
                marker: entry.marker == .ring ? .ring : .bar,
                title: entry.title,
                gloss: entry.gloss,
                examStar: entry.isExamAdmission,
                day: entry.date.map(text.day) ?? "",
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
    }

    @ViewBuilder
    private func menu(_ entry: ComingUpEntry) -> some View {
        if let reply = entry.reply {
            Button("Open Message") { open(reply) }
            Button("No Reply Needed") { clearNeedsReply(reply.id) }
        } else if let session = entry.session {
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

    /// A session's range, an item's due time; nothing for an all-day or undated item.
    private func time(_ entry: ComingUpEntry) -> String? {
        guard let date = entry.date else { return nil }
        if let end = entry.end { return text.timeRange(date, end) }
        return entry.isAllDay ? nil : DayText.time(date, timeZone: text.timeZone)
    }

    /// The mail in Mail.
    private func open(_ reply: TodayReply) {
        openDestination(.mail(reply.scope, message: reply.id))
    }

    /// No Reply Needed: the mail stops asking (`needs_reply` false); a local flag, no server effect.
    private func clearNeedsReply(_ id: MailMessage.ID) {
        guard let services else { return }
        Task {
            do {
                let stamp = services.records.currentDate
                try await services.database.write { db in
                    try MailMessage.find(id).update {
                        $0.needsReply = Bool?.some(false)
                        $0.updatedAt = stamp
                    }
                    .execute(db)
                }
            } catch {
                CoursesUILog.ui.error("No Reply Needed failed: \(error.localizedDescription, privacy: .private)")
            }
        }
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
        var parts = [course?.name ?? "", entry.title, entry.date.map(text.day) ?? ""]
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

/// One row of Coming up on the iPhone (mockup 16 `.r`): [the 4 pt course bar or the 10 pt ring |
/// the title (15 semibold) over at most one 13 pt grey gloss (the amber star first for exam
/// admission), the source glyph after the last line | the day (15) over the time (SF Mono 12.5,
/// secondary) or "and Fri 13 Nov"]. Cancelled: struck through in tertiary.
private struct PhoneComingUpRow<Accessory: View>: View {
    let color: Color
    let isRing: Bool
    let title: String
    let gloss: String?
    let examStar: Bool
    let day: String
    let time: String?
    let dayNote: String?
    let isStruck: Bool
    let accessory: Accessory

    init(
        color: Color, isRing: Bool, title: String, gloss: String?, examStar: Bool = false, day: String, time: String? = nil,
        dayNote: String? = nil, isStruck: Bool = false, @ViewBuilder accessory: () -> Accessory
    ) {
        self.color = color
        self.isRing = isRing
        self.title = title
        self.gloss = gloss.flatMap { $0.isEmpty ? nil : $0 }
        self.examStar = examStar
        self.day = day
        self.time = time
        self.dayNote = dayNote
        self.isStruck = isStruck
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            marker
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(isStruck)
                        .foregroundStyle(isStruck ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .frame(minHeight: 20)
                    if gloss == nil { accessory }
                }
                if let gloss {
                    HStack(spacing: 5) {
                        if examStar {
                            Image(systemName: "star")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.professor)
                                .accessibilityLabel(Text("Exam admission"))
                        }
                        Text(gloss)
                            .lineLimit(1)
                        accessory
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                if !day.isEmpty {
                    Text(day)
                        .font(.subheadline)
                        .frame(minHeight: 20)
                }
                if let time {
                    Text(time)
                        .font(.mono(12.5))
                        .monospacedDigit()
                        .foregroundStyle(isStruck ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                        .frame(minHeight: 18)
                }
                if let dayNote {
                    Text(dayNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 18)
                }
            }
            .strikethrough(isStruck)
            .foregroundStyle(isStruck ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var marker: some View {
        if isRing {
            DueRing(color: color)
                .padding(.top, 5)
        } else {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
        }
    }
}

/// The mail line (mockup 01): 42 pt over a hairline, 8 pt closer to Coming up. It only counts:
/// what the course mail said is already in the rows. On the iPhone (M7) 15 pt, 48 pt tall.
struct TodayMailLine: View {
    let line: MailLine
    let courses: [Course.ID: Course]
    var isPhone = false

    @Environment(\.openDestination) private var openDestination

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.system(size: isPhone ? 15 : 13))
                .frame(width: isPhone ? 18 : 15, height: 15)
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
                    .font(isPhone ? .subheadline.weight(.medium) : .system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(isPhone ? .subheadline : .system(size: 12.5))
        .foregroundStyle(.secondary)
        .frame(minHeight: isPhone ? 48 : 42)
        .padding(.horizontal, isPhone ? 4 : 0)
        .overlay(alignment: .top) {
            Hairline()
        }
        .padding(.top, isPhone ? 0 : -8)
    }

    private var newsletters: String {
        line.newsletters == 1
            ? String(localized: "· 1 newsletter")
            : String(localized: "· \(line.newsletters) newsletters")
    }
}
