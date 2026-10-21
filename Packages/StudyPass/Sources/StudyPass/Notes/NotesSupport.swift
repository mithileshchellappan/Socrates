import Foundation
import StudyCore

// ln (docs/plan-lecture-notes.md §5.4): what the notes writer and the asker share. Chips are
// checked against the course's lectures, their slide ranges and recording lengths (an unknown
// lecture, a page outside the range, a moment past the recording's end: dropped, never shown);
// prose loses links, images and stray note markers; fences are written back with enough backticks.

/// The course's lectures as chips may name them.
struct NotesChips: Sendable {
    struct Target: Sendable {
        var id: Lecture.ID
        /// Its slides (`LectureSlides.current`), or the pages the study pass read for it.
        var pages: Set<Int>
        /// Its recordings by key with their lengths (seconds; 0: unknown), the first one first.
        var recordings: [(key: String, duration: Double)]
    }

    /// By lecture key; a key two lectures share names neither.
    var lectures: [String: Target]

    /// The course's lectures (`courseID`); `extraPages` adds pages one lecture's chips may name
    /// beyond its range (a capture's deck without a range).
    static func load(courseID: Course.ID, extraPages: [Lecture.ID: [Int]] = [:], in db: Database) throws -> NotesChips {
        let lectures = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let ids = Set(lectures.map(\.id))
        let recordings = try Recording.where { $0.lectureID.isNot(nil) }.order(by: \.startedAt).fetchAll(db)
            .filter { $0.lectureID.map(ids.contains) ?? false }
        var byKey: [String: Target] = [:]
        var shared: Set<String> = []
        for lecture in lectures {
            let key = ChatCitation.key(lecture.id)
            if byKey[key] != nil {
                shared.insert(key)
                continue
            }
            var pages: Set<Int> = Set(extraPages[lecture.id] ?? [])
            if let range = try LectureSlides.current(lectureID: lecture.id, in: db) {
                pages.formUnion(range.firstPage...max(range.firstPage, range.lastPage))
            }
            let own = recordings.filter { $0.lectureID == lecture.id }.map { (key: ChatCitation.key($0.id), duration: $0.duration) }
            byKey[key] = Target(id: lecture.id, pages: pages, recordings: own)
        }
        for key in shared { byKey[key] = nil }
        return NotesChips(lectures: byKey)
    }

    /// Whether a chip may show: a slide in its lecture's range, a moment within its recording.
    /// Web pages, changes and documents never belong in the notes.
    func isValid(_ citation: ChatCitation) -> Bool {
        switch citation {
        case .slide(let key, let page):
            guard let target = lectures[key] else { return false }
            return target.pages.contains(page)
        case .moment(let key, let recording, let seconds):
            guard let target = lectures[key] else { return false }
            let found = recording.map { wanted in target.recordings.first { $0.key == wanted } } ?? target.recordings.first
            guard let found else { return false }
            return found.duration <= 0 ? seconds < 6 * 3_600 : Double(seconds) <= found.duration + 1
        case .web, .change, .document:
            return false
        case .material:
            // mt: book passages' markers (workstream B: only those given in the input).
            return false
        }
    }

    /// `text` with its invalid chips taken out (and the gap they leave); the number dropped.
    func filtered(_ text: String) -> (text: String, dropped: Int) {
        var output = ""
        var dropped = 0
        var closeGap = false
        for piece in ChatCitation.pieces(of: text) {
            switch piece {
            case .text(let words):
                if closeGap, output.hasSuffix(" "), let first = words.first, first == " " || ".,;:!?)".contains(first) {
                    output.removeLast()
                }
                closeGap = false
                output += words
            case .citation(let citation):
                if isValid(citation) {
                    output += citation.marker
                } else {
                    dropped += 1
                    closeGap = true
                }
            }
        }
        if closeGap, output.hasSuffix(" ") { output.removeLast() }
        return (output, dropped)
    }
}

enum NotesProse {
    /// A prose run as the notes keep it: checked chips; links keep their text (no web in v1);
    /// images go (slides come only through `slide`); a note marker outside a `note` fence goes.
    static func cleaned(_ text: String, chips: NotesChips) -> (text: String, dropped: Int) {
        var text = text.replacingOccurrences(of: #"!\[[^\]\n]*\]\([^)\n]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]\n]+)\]\((?:https?|mailto):[^)\n]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #" ?\[\[note [0-9a-f]{8}\]\]"#, with: "", options: .regularExpression)
        return chips.filtered(text)
    }

    /// A fenced block as Markdown: as many backticks as it needs (three, or one more than the
    /// longest run inside).
    static func fence(_ info: String, _ body: String) -> String {
        var longest = 0
        var run = 0
        for character in body {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        return "\(ticks)\(info)\n\(body)\n\(ticks)"
    }
}

/// ln: text the agent keeps on the notes (keep_notes_answer) with its chips checked as the
/// notes' are (the course's lectures, their slide ranges and recording lengths).
public enum NotesChipCheck {
    public static func checked(_ text: String, courseID: Course.ID, in db: Database) throws -> String {
        NotesProse.cleaned(text, chips: try NotesChips.load(courseID: courseID, in: db)).text
    }
}

/// How long a version of lecture notes is.
public enum NotesWords {
    /// Words of the prose (headings, paragraphs, lists, tables, callouts), without chips, markers
    /// and fences: "notes · 2,140 words" (the agent's catalog). Check yourself is not counted.
    public static func count(_ body: String) -> Int {
        var words = 0
        for part in LectureNotesFormat.parse(body).parts {
            for case .markdown(let text) in part.blocks {
                for piece in ChatCitation.pieces(of: text) {
                    if case .text(let run) = piece { words += TextRules.wordCount(run) }
                }
            }
        }
        return words
    }
}
