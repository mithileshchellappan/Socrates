import Courses
import StudyCore
import StudyUI
import SwiftUI

/// What a detail popover's buttons do; the screen wires them to `DeadlineActions` and navigation.
struct DetailHandlers {
    var openLecture: (Lecture.ID) -> Void
    var openCourse: (Course.ID) -> Void
    var cancelSession: (LectureSession.ID) -> Void
    var restoreSession: (LectureSession.ID) -> Void
    var confirm: (TrackedItem.ID) -> Void
    var discard: (TrackedItem.ID) -> Void
    var complete: (TrackedItem.ID) -> Void
    var remove: (TrackedItem.ID) -> Void
    var addToCalendar: (TrackedItem.ID) -> Void
    var trail: (TrackedItem.ID) -> TrailInfo
    /// The next deadline's row: selects it (and its inspector row).
    var selectItem: (TrackedItem) -> Void
}

/// A grid item's detail popover (docs/DESIGN.md §8.3), like Calendar.app's event popover: the
/// course dot and title, the facts as rows under a 16 pt glyph column (mono times), what changed
/// with its sources, the session's lecture and its course's next deadline, the item's source
/// trail, and the actions in a footer (at most one filled button: Open Lecture).
struct CalendarDetail: View {
    static let width: CGFloat = 300

    let target: CalendarSelection
    let data: CalendarData
    let now: Date
    let handlers: DetailHandlers

    var body: some View {
        Group {
            switch target {
            case .session(let id):
                if let session = data.sessions.first(where: { $0.id == id }) {
                    SessionDetail(session: session, data: data, now: now, handlers: handlers)
                }
            case .item(let id):
                if let item = data.item[id] {
                    ItemDetail(item: item, data: data, now: now, handlers: handlers)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .padding(.horizontal, 14)
        .frame(width: Self.width, alignment: .leading)
    }
}

// MARK: - Session

private struct SessionDetail: View {
    let session: LectureSession
    let data: CalendarData
    let now: Date
    let handlers: DetailHandlers

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var course: Course? { data.courses[session.courseID] }
    private var lectureID: Lecture.ID? { data.lectures[session.id] }
    private var tied: [TrackedItem] { data.sessionItems[session.id] ?? [] }
    /// The course's next open due item from now (one already listed as tied to the session is
    /// not repeated).
    private var nextDue: TrackedItem? {
        let tiedIDs = Set(tied.map(\.id))
        return data.upcoming.first { $0.courseID == session.courseID && ($0.dueAt ?? .distantPast) >= now && !tiedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(course: course, title: CalendarText.sessionTitle(session, course: course), isCancelled: session.isCancelled)
            VStack(alignment: .leading, spacing: 8) {
                FactRow(glyph: "clock") {
                    DetailText.when(session.startsAt, end: session.endsAt, locale: locale, timeZone: timeZone)
                    if let slot = session.weeklySlotID.flatMap({ data.slots[$0] }) {
                        Text(CalendarText.recurrence(slot)).detailSecondary()
                    }
                }
                let place = CalendarText.place(session.room)
                if !place.room.isEmpty {
                    FactRow(glyph: "mappin.and.ellipse") {
                        Text(place.room)
                        if let location = place.location {
                            Text(location).detailSecondary()
                        }
                    }
                }
                let lecturers = (course?.professors ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !lecturers.isEmpty {
                    FactRow(glyph: "graduationcap") {
                        Text(lecturers.joined(separator: ", "))
                    }
                }
            }
            .padding(.top, 10)

            ForEach(tied) { item in
                DetailDivider()
                ChangeBlock(item: item, session: session, trail: handlers.trail(item.id), now: now, handlers: handlers)
            }

            if let lectureID, let info = data.lectureInfo[lectureID] {
                DetailDivider()
                FactRow(glyph: "waveform") {
                    Text(CalendarText.lectureTitle(info.lecture))
                        .font(.system(size: 13, weight: .medium))
                    if let duration = info.duration {
                        Text(verbatim: TimeText.clock(duration))
                            .font(.mono(11.5))
                            .foregroundStyle(.secondary)
                    }
                    if let line = CalendarText.studyLine(info) {
                        Text("\(Text(Image(systemName: "sparkle")).font(.system(size: 10)).foregroundStyle(Color.ai)) \(line)")
                            .detailSecondary()
                            .accessibilityLabel(Text(line))
                    }
                }
            }

            if let nextDue {
                DetailDivider()
                NextDueRow(item: nextDue, course: course, data: data, handlers: handlers)
            }

            DetailDivider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if session.isCancelled {
                Button("Restore Session") { handlers.restoreSession(session.id) }
            } else {
                Button("Cancel Session") { handlers.cancelSession(session.id) }
            }
            Spacer(minLength: 8)
            if let undo = tied.lazy.compactMap({ handlers.trail($0.id).undo }).first {
                Button(action: undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
            }
            if let lectureID {
                Button("Open Lecture") { handlers.openLecture(lectureID) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Open Course") { handlers.openCourse(session.courseID) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
    }
}

/// An item tied to the session: a waiting room change or cancellation (sparkle + question with
/// Discard and Confirm), a settled one ("Moved to Room 5", "Cancelled"; ma: "Moved to Tue 20 Oct,
/// 10:15", "Extra session", applied on their own, Undo in the footer), or an event that is the
/// session (its title and grey gloss); then its sources.
private struct ChangeBlock: View {
    let item: TrackedItem
    let session: LectureSession
    let trail: TrailInfo
    let now: Date
    let handlers: DetailHandlers

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let waiting = item.kind.isSessionProposal && item.status == .open
        let details = item.details.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if waiting { AIMark() }
                Text(CalendarText.change(item, session: session, locale: locale, timeZone: timeZone))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 6)
                if waiting {
                    Button("Discard") { handlers.discard(item.id) }
                        .foregroundStyle(.secondary)
                    Button("Confirm") { handlers.confirm(item.id) }
                        .foregroundStyle(.tint)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            if !details.isEmpty, !waiting {
                Text(details).detailSecondary()
            }
            SourceTrailRows(entries: trail.entries, now: now)
                .padding(.horizontal, -4)
        }
    }
}

/// The course's next deadline, as one row: [due ring | title over "Thu 29 Oct, 23:59"].
private struct NextDueRow: View {
    let item: TrackedItem
    let course: Course?
    let data: CalendarData
    let handlers: DetailHandlers

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Button { handlers.selectItem(item) } label: {
            HStack(alignment: .top, spacing: 8) {
                DueRing(course: course)
                    .frame(width: 16)
                    .padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if item.relevance == .examAdmission {
                            ExamAdmissionChip()
                        }
                    }
                    if let due = item.dueAt {
                        DetailText.due(due, allDay: item.isAllDay, session: nil, course: course, locale: locale, timeZone: timeZone)
                            .detailSecondary()
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Item

/// A deadline, exercise, exam, task or event: title, kind, when, where, the gloss, the verified
/// source quotes (a mail row opens the mail, a recording row plays the lecture at the second), and
/// the green check or Add to Calendar, Undo or Delete, Mark as Done.
private struct ItemDetail: View {
    let item: TrackedItem
    let data: CalendarData
    let now: Date
    let handlers: DetailHandlers

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var course: Course? { item.courseID.flatMap { data.courses[$0] } }

    var body: some View {
        let trail = handlers.trail(item.id)
        let place = CalendarText.place(item.room ?? "")
        let details = item.details.trimmingCharacters(in: .whitespacesAndNewlines)
        // A timetable item's details are its rooms, already on the room row.
        let gloss = details == place.room ? "" : details
        VStack(alignment: .leading, spacing: 0) {
            DetailHeader(course: course, title: item.title)
            HStack(spacing: 7) {
                Text(kindLine).detailSecondary()
                if item.relevance == .examAdmission {
                    ExamAdmissionChip()
                }
            }
            .padding(.leading, DetailHeader.textInset)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                if let due = item.dueAt {
                    FactRow(glyph: "clock") {
                        DetailText.due(
                            due, allDay: item.isAllDay, session: item.lectureSessionID.flatMap { data.linkedSessions[$0] },
                            course: course, locale: locale, timeZone: timeZone
                        )
                    }
                }
                if !place.room.isEmpty {
                    FactRow(glyph: "mappin.and.ellipse") {
                        Text(place.room)
                        if let location = place.location {
                            Text(location).detailSecondary()
                        }
                    }
                }
                if !gloss.isEmpty {
                    // The extractor's gloss: grey with one sparkle; the student's own stays primary.
                    let isAI = item.createdBy != .user
                    HStack(alignment: .top, spacing: 8) {
                        AIMark()
                            .opacity(isAI ? 1 : 0)
                            .frame(width: 16, height: 16)
                        Text(gloss)
                            .font(.system(size: 12))
                            .foregroundStyle(isAI ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 10)

            if trail.entries.contains(where: \.isActive) {
                DetailDivider()
                SourceTrailRows(entries: trail.entries, now: now)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -4)
            }

            DetailDivider()
            footer(trail)
        }
    }

    /// "Exam", or "Data Centers · Exercise" when the title does not name the course.
    private var kindLine: String {
        let kind = CalendarText.kindName(item.kind)
        guard let name = course?.name.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              item.title.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        else { return kind }
        return "\(name) · \(kind)"
    }

    private func footer(_ trail: TrailInfo) -> some View {
        HStack(spacing: 8) {
            if item.inCalendar {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("In Calendar"))
            } else if item.dueAt != nil {
                Button("Add to Calendar") { handlers.addToCalendar(item.id) }
            }
            Spacer(minLength: 8)
            if let undo = trail.undo {
                Button(action: undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button("Delete") { handlers.remove(item.id) }
            }
            if item.kind != .event {
                Button("Mark as Done") { handlers.complete(item.id) }
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Pieces

/// The course dot (10) and the title (15 semibold); struck through in tertiary when cancelled.
private struct DetailHeader: View {
    /// Where text under the title starts (dot + spacing).
    static let textInset: CGFloat = 18

    let course: Course?
    let title: String
    var isCancelled = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CourseDot(course: course, size: 10)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .strikethrough(isCancelled)
                .foregroundStyle(isCancelled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One fact: a 16 pt secondary glyph, then its lines (13 primary over 12 secondary).
private struct FactRow<Content: View>: View {
    let glyph: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A hairline between the popover's blocks.
private struct DetailDivider: View {
    var body: some View {
        Hairline()
            .padding(.vertical, 10)
    }
}

private extension View {
    /// A grey second line: 12 pt secondary.
    func detailSecondary() -> some View {
        font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

/// Days and times of the popover: the day as every screen writes it, times in SF Mono.
private enum DetailText {
    /// "Mon 19 Oct, 12:15–13:45".
    static func when(_ start: Date, end: Date, locale: Locale, timeZone: TimeZone) -> Text {
        let day = DayText.day(start, locale: locale, timeZone: timeZone)
        let range = Text(verbatim: DayText.timeRange(start, end, timeZone: timeZone)).font(.mono(12.5))
        return Text("\(day), \(range)").monospacedDigit()
    }

    /// "Mon 19 Oct, 23:59", the day alone when all-day, " · SN seminar" when tied to a session.
    static func due(
        _ date: Date, allDay: Bool, session: LectureSession?, course: Course?, locale: Locale, timeZone: TimeZone
    ) -> Text {
        var text = Text(verbatim: DayText.day(date, locale: locale, timeZone: timeZone))
        if !allDay {
            let time = Text(verbatim: DayText.time(date, timeZone: timeZone)).font(.mono(12.5))
            text = Text("\(text), \(time)")
        }
        if let session {
            let name = SessionText.title(of: session, courseName: course?.name ?? "", shortName: course?.shortName ?? "")
            text = Text("\(text) · \(name)")
        }
        return text.monospacedDigit()
    }
}

// MARK: - Render preview

/// Off-screen renders (`tools/parity/render --calendar-sample`): which item's detail the
/// Calendar draws inline, as an open popover would show it (an off-screen window draws no popover).
public enum CalendarDetailPreview: Hashable, Sendable {
    /// The week's first session whose lecture has study-pass rows (else a recording, else any
    /// lecture, else a change, else the first session).
    case session
    /// The week's first exam (else its first event block, else its first due item).
    case exam
}

extension EnvironmentValues {
    /// Set only by off-screen renders.
    @Entry public var calendarDetailPreview: CalendarDetailPreview?
}

extension CalendarDetailPreview {
    /// The grid item to show, from the week's plan and rows.
    func target(plan: WeekPlan, data: CalendarData) -> CalendarSelection? {
        switch self {
        case .session:
            let sessions = plan.events.filter { $0.sessionID != nil }
            func info(_ event: WeekPlan.Event) -> LectureInfo? { event.lectureID.flatMap { data.lectureInfo[$0] } }
            let pick = sessions.first { (info($0)?.highlights ?? 0) > 0 }
                ?? sessions.first { info($0)?.duration != nil }
                ?? sessions.first { $0.lectureID != nil }
                ?? sessions.first { $0.sessionID.flatMap { data.sessionItems[$0] }?.isEmpty == false }
                ?? sessions.first
            return pick?.target
        case .exam:
            if let exam = data.weekItems.first(where: { $0.kind == .exam }) { return .item(exam.id) }
            if let block = plan.events.first(where: { $0.itemID != nil }) { return block.target }
            return plan.dues.first.map { .item($0.id) }
        }
    }
}

/// The popover's content drawn as a card where the system would put the popover (renders only).
struct DetailCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}
