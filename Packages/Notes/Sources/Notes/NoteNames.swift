import Foundation
import StudyCore

/// Where a note sits, for its name: the course's short name and the lecture's number ("DC", 2).
public struct NotePlace: Hashable, Sendable {
    public var courseShortName: String?
    public var lectureNumber: Int?

    public init(courseShortName: String? = nil, lectureNumber: Int? = nil) {
        self.courseShortName = courseShortName
        self.lectureNumber = lectureNumber
    }

    public init(course: Course?, lecture: Lecture?) {
        let short = course.map { $0.shortName.isEmpty ? $0.name : $0.shortName }
        self.init(courseShortName: short, lectureNumber: lecture?.number)
    }

    /// "DC L2", "DC", "L2"; nil when nothing is known.
    public var label: String? {
        let parts = [courseShortName.flatMap { $0.isEmpty ? nil : $0 }, lectureNumber.map { "L\($0)" }].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Note names, titles and previews (docs/plan-m6.md §4, DESIGN 8.4).
///
/// A note's title is its first block when that is a level-1 heading. The list names a note by:
/// 1. its title;
/// 2. else "DC L2 · Slide 15" (a note on a slide);
/// 3. else "DC L2 · " + its first line (a lecture's note);
/// 4. else its first line;
/// 5. else "New Note".
public enum NoteNames {
    /// The note's own title: the first block when it is a non-empty level-1 heading.
    public static func title(of blocks: [NoteBlock]) -> String? {
        guard let first = blocks.first, first.type == .heading, (first.level ?? 1) == 1 else { return nil }
        let text = firstLine(of: first.text)
        return text.isEmpty ? nil : text
    }

    /// The name the list (and Search) shows for `note`.
    public static func name(of note: Note, place: NotePlace) -> String {
        name(blocks: note.blocks, place: place, isSlideNote: note.pageNumber != nil, page: note.pageNumber, isLectureNote: note.lectureID != nil)
    }

    public static func name(blocks: [NoteBlock], place: NotePlace, isSlideNote: Bool, page: Int?, isLectureNote: Bool) -> String {
        if let title = title(of: blocks) { return title }
        if isSlideNote, let page {
            let slide = String(localized: "Slide \(page)")
            return place.label.map { "\($0) · \(slide)" } ?? slide
        }
        let line = firstTextLine(of: blocks)?.text
        if isLectureNote, let label = place.label {
            return line.map { "\(label) · \($0)" } ?? label
        }
        return line ?? String(localized: "New Note")
    }

    /// The list row's grey line: the first line of text after what the name already says.
    public static func preview(of note: Note) -> String {
        preview(blocks: note.blocks, namedByText: note.pageNumber == nil)
    }

    /// `namedByText`: the name used the first line when there is no title (not a slide note).
    public static func preview(blocks: [NoteBlock], namedByText: Bool) -> String {
        var skip: Int?
        if title(of: blocks) != nil {
            skip = 0
        } else if namedByText {
            skip = firstTextLine(of: blocks)?.index
        }
        let start = skip.map { $0 + 1 } ?? 0
        for block in blocks.dropFirst(start) {
            let line = firstLine(of: block.text)
            if !line.isEmpty { return line }
        }
        return ""
    }

    /// The first block with visible text, and that text's first line.
    static func firstTextLine(of blocks: [NoteBlock]) -> (index: Int, text: String)? {
        for (index, block) in blocks.enumerated() {
            let line = firstLine(of: block.text)
            if !line.isEmpty { return (index, line) }
        }
        return nil
    }

    static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
