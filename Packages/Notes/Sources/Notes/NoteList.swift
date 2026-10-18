import Foundation
import StudyCore

/// One row of the Notes screen's list: the note, its name and grey preview line.
public struct NoteListItem: Identifiable, Hashable, Sendable {
    public var note: Note
    public var name: String
    public var preview: String

    public var id: Note.ID { note.id }

    public init(note: Note, name: String, preview: String) {
        self.note = note
        self.name = name
        self.preview = preview
    }
}

/// A group of the list: a course's notes under its header, or (course nil) the notes without a
/// course, which come last and have no header.
public struct NoteListSection: Identifiable, Hashable, Sendable {
    public var course: Course?
    public var items: [NoteListItem]

    public var id: Course.ID? { course?.id }

    public init(course: Course?, items: [NoteListItem]) {
        self.course = course
        self.items = items
    }
}

/// The Notes screen's list (mockup 04): names, filtering and grouping.
public enum NoteList {
    /// Rows for `notes`, newest first, filtered by `query` (every word must occur in the name or
    /// the text; case and diacritics folded). Blank notes are left out.
    public static func items(
        _ notes: [Note],
        courses: [Course.ID: Course],
        lectures: [Lecture.ID: Lecture],
        query: String = ""
    ) -> [NoteListItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        return notes
            .filter { !$0.isBlank }
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
            .compactMap { note in
                let place = NotePlace(
                    course: note.courseID.flatMap { courses[$0] },
                    lecture: note.lectureID.flatMap { lectures[$0] }
                )
                let blocks = note.blocks
                let name = NoteNames.name(
                    blocks: blocks, place: place, isSlideNote: note.pageNumber != nil, page: note.pageNumber,
                    isLectureNote: note.lectureID != nil
                )
                if !terms.isEmpty {
                    let haystack = fold(name + "\n" + NoteBlock.plainText(of: blocks))
                    guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
                }
                return NoteListItem(note: note, name: name, preview: NoteNames.preview(blocks: blocks, namedByText: note.pageNumber == nil))
            }
    }

    /// All Notes: one section per course in the courses' order (each newest first), then the
    /// notes without a course (no header). `items` must already be newest first.
    public static func sections(_ items: [NoteListItem], courses: [Course]) -> [NoteListSection] {
        let ordered = courses.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        var sections: [NoteListSection] = []
        for course in ordered {
            let mine = items.filter { $0.note.courseID == course.id }
            if !mine.isEmpty { sections.append(NoteListSection(course: course, items: mine)) }
        }
        let known = Set(ordered.map(\.id))
        let rest = items.filter { $0.note.courseID.map { !known.contains($0) } ?? true }
        if !rest.isEmpty { sections.append(NoteListSection(course: nil, items: rest)) }
        return sections
    }

    /// Case- and diacritic-insensitive form for matching.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// The list row's time (DESIGN 8.4): the clock today ("09:41", SF Mono), "Yesterday", the weekday
/// within the last week ("Wednesday"), else the day ("Mon 12 Oct", `DayText.day`).
public enum NoteListTime: Hashable, Sendable {
    case clock(Date)
    case yesterday
    case weekday(Date)
    case day(Date)

    public init(_ date: Date, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ...0: self = .clock(date)
        case 1: self = .yesterday
        case 2..<7: self = .weekday(date)
        default: self = .day(date)
        }
    }
}
