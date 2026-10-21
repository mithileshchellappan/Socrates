import Foundation
import StudyCore

/// What the notes writer reads about one lecture (docs/plan-lecture-notes.md §5.3), loaded in one
/// read: the slides in the lecture's range (text ≤ 1,200 characters, figure lines, per-slide
/// summaries), the corrected transcript in full with times, the sections (topics, or for a lecture
/// with slides only the deck's own groups of slides) with their word budgets, the professor's exam
/// hints and highlights, what was said in class, the student's flags, notes (≤ 2,000 words) and
/// preferences, the glossary, and the outlines of the course's earlier notes (≤ 1,500 words). No
/// document-bank text and no web, so the notes may sync.
struct NotesMaterial: Sendable {
    struct Slide: Sendable {
        var page: Int
        var title: String
        var text: String
        var summary: String?
        var figure: String?
        /// Transcript lines said while it was on screen (its weight for images and budgets).
        var lines: Int

        var words: Int { TextRules.wordCount(text) }
    }

    struct Line: Sendable {
        var start: Double
        var end: Double
        var text: String
        var page: Int?
        var flagged: Bool
    }

    struct StudentNote: Sendable {
        var id: Note.ID
        /// The first 8 hex of its id (`[[note 7f3a20c1]]`).
        var key: String
        var page: Int?
        var time: Double?
        var text: String
    }

    static let slideTextLimit = 1_200
    static let noteWordLimit = 2_000
    static let earlierWordLimit = 1_500
    static let maximumImages = 3
    static let figureTextLimit = 80
    static let minimumSectionWords = 150

    var notesID: LectureNotes.ID
    var lecture: Lecture
    var course: Course?
    var source: LectureNotesSource
    /// The Write Again sentence.
    var request: String?
    var deck: Deck?
    var slides: [Slide]
    var lines: [Line]
    /// The lecture's key ("9a7d94d1").
    var lectureKey: String
    /// The recording the transcript is of; its key when it is not the lecture's first.
    var recordingID: Recording.ID?
    var recordingKey: String?
    /// Seconds of that recording (0 without one).
    var duration: Double
    var sections: [LectureNotesSection]
    var targetWords: Int
    var length: NotesLength
    /// Exam hints and highlights (`professor` layer), by time.
    var professor: [Annotation]
    /// Said in class, not on the slides, by time.
    var said: [Annotation]
    var notes: [StudentNote]
    var preferences: [String]
    var glossary: [String]
    /// The course's earlier notes: one line per section ("L2 3b1f08aa · Message ordering · S10–16: …").
    var earlier: [String]
    /// Figure slides whose images go along (≤ 3); only these may carry a `box`.
    var imagePages: [Int]
    var language: String
    var chips: NotesChips

    var isGerman: Bool { language.lowercased().hasPrefix("de") }

    /// A moment chip of this lecture's transcript.
    func moment(_ seconds: Double) -> String {
        "[[\(lectureKey)\(recordingKey.map { "/" + $0 } ?? "") \(ChatCitation.clock(max(0, Int(seconds.rounded(.down)))))]]"
    }

    func slide(_ page: Int) -> String {
        ChatCitation.slide(lecture.id, page: page).marker
    }

    /// "Lecture 3: Time and Logical Clocks".
    var lectureName: String {
        let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = lecture.number else { return title.isEmpty ? "Lecture" : title }
        return title.isEmpty ? "Lecture \(number)" : "Lecture \(number): \(title)"
    }

    var courseName: String {
        guard let course else { return "" }
        return course.shortName.isEmpty || course.shortName == course.name ? course.name : "\(course.name) (\(course.shortName))"
    }

    // MARK: - Loading

    /// Nil when the lecture is gone or there is nothing to write from. `keepSections`: the
    /// version's outline as begun (a resume keeps its keys); else the outline now.
    static func load(_ notes: LectureNotes, keepSections: Bool, in db: Database) throws -> NotesMaterial? {
        guard let lecture = try Lecture.find(notes.lectureID).fetchOne(db) else { return nil }
        let lectureID = lecture.id
        let reference = Lecture.ID?.some(lectureID)
        let course = try Course.find(lecture.courseID).fetchOne(db)
        let range = try LectureSlides.current(lectureID: lectureID, in: db)
        let study: LectureMaterial? = notes.source == .recording ? try LectureMaterial.load(lectureID, in: db) : nil

        // The slides.
        var deck: Deck?
        var pageRows: [DeckPage] = []
        if let range {
            pageRows = try LectureSlides.pages(of: range, in: db)
            deck = try Deck.find(range.deckID).fetchOne(db)
        } else if let study {
            pageRows = study.lecturePages.compactMap { study.pages[$0] }
            deck = study.deck
        }
        let rows = try Annotation.where { $0.lectureID.eq(reference) && $0.hiddenAt.is(nil) }.fetchAll(db)
        var summaries: [Int: String] = [:]
        var figures: [Int: String] = [:]
        for row in rows {
            guard let page = row.pageNumber else { continue }
            if row.kind == .summary, row.layer == .ai, summaries[page] == nil { summaries[page] = row.body }
            if row.kind == .studyFigure, figures[page] == nil { figures[page] = row.body }
        }
        var linesOnPage: [Int: Int] = [:]
        var lines: [Line] = []
        if let study {
            for line in study.lines {
                let page = study.page(ofLine: line.index)
                if let page { linesOnPage[page, default: 0] += 1 }
                lines.append(Line(start: line.start, end: line.end, text: line.text, page: page, flagged: line.flagged))
            }
        }
        let slides = pageRows.sorted { $0.pageNumber < $1.pageNumber }.map { page in
            Slide(
                page: page.pageNumber, title: DeckPage.title(fromPageText: page.text), text: page.text, summary: summaries[page.pageNumber],
                figure: figures[page.pageNumber], lines: linesOnPage[page.pageNumber] ?? 0
            )
        }
        guard !slides.isEmpty || !lines.isEmpty else { return nil }

        // The recording the transcript is of, and whether chips name it.
        var recordingID: Recording.ID?
        var recordingKey: String?
        var duration: Double = 0
        if let study {
            recordingID = study.recordingID
            let first = try Recording.where { $0.lectureID.eq(reference) }.order(by: \.startedAt).fetchOne(db)
            if let first, first.id != study.recordingID { recordingKey = ChatCitation.key(study.recordingID) }
            let main = try Recording.find(study.recordingID).fetchOne(db)
            duration = max(main?.duration ?? 0, lines.last?.end ?? 0)
        }

        // What the professor said and what was said in class.
        let byTime: (Annotation, Annotation) -> Bool = { ($0.startTime ?? 0, $0.pageNumber ?? 0) < ($1.startTime ?? 0, $1.pageNumber ?? 0) }
        let professor = rows.filter { ($0.kind == .examHint || $0.kind == .highlight) && $0.startTime != nil }.sorted(by: byTime)
        let said = rows.filter { $0.kind == .notOnSlides }.sorted(by: byTime)

        // The student's notes on the lecture's slides and moments.
        var notesOut: [StudentNote] = []
        for note in try Note.where({ $0.lectureID.eq(reference) }).order(by: \.createdAt).fetchAll(db) {
            guard note.pageNumber != nil || note.audioTime != nil else { continue }
            let text = NoteBlock.plainText(of: (try? NoteBlock.decode(note.blocksJSON)) ?? []).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            notesOut.append(StudentNote(id: note.id, key: ChatCitation.key(note.id), page: note.pageNumber, time: note.audioTime, text: text))
        }

        // Preferences and the length rule.
        let memories = try AgentMemory
            .where { $0.forgottenAt.is(nil) && $0.kind.eq(AgentMemoryKind.preference) }
            .order { $0.updatedAt.desc() }
            .fetchAll(db)
        let length = NotesRules.length(memories: memories, courseID: lecture.courseID)

        // The outline.
        var sections: [LectureNotesSection]
        if keepSections, !notes.sections.isEmpty {
            sections = notes.sections
        } else {
            sections = notes.source == .recording ? try LectureNotesRepository.outline(lectureID: lectureID, in: db) : []
            if sections.isEmpty { sections = slideGroups(slides) }
            if sections.isEmpty {
                let title = lecture.title.isEmpty ? "Lecture" : lecture.title
                sections = [LectureNotesSection(
                    key: LectureNotesFormat.sectionKey(topicTitle: title), title: title, startTime: lines.first?.start, endTime: nil
                )]
            }
        }
        let target = targetWords(source: study == nil ? .slides : .recording, duration: duration, slides: slides, length: length)
        if !(keepSections && sections.allSatisfy { $0.targetWords != nil }) {
            sections = budgets(sections, total: target, end: duration, slides: slides)
        }

        // The course's earlier notes, for connections.
        let earlier = try earlierOutlines(lecture, in: db)

        var extraPages: [Lecture.ID: [Int]] = [:]
        extraPages[lectureID] = slides.map(\.page)
        let chips = try NotesChips.load(courseID: lecture.courseID, extraPages: extraPages, in: db)
        let language = [lecture.language, course?.language ?? "", study?.language ?? ""].first { !$0.isEmpty } ?? ""
        return NotesMaterial(
            notesID: notes.id, lecture: lecture, course: course, source: notes.source, request: notes.request, deck: deck, slides: slides,
            lines: lines, lectureKey: ChatCitation.key(lectureID), recordingID: recordingID, recordingKey: recordingKey, duration: duration,
            sections: sections, targetWords: target, length: length, professor: professor, said: said, notes: notesOut,
            preferences: memories.map(\.text), glossary: Array((course?.glossaryTerms ?? []).prefix(80)), earlier: earlier,
            imagePages: imagePages(slides, hasRecording: study != nil), language: language, chips: chips
        )
    }

    // MARK: - Sections and budgets

    /// A lecture with slides only: the deck's own groups. Divider slides (a title alone) start a
    /// group when they make 2–10 of them; else runs of slides with the same title, merged into at
    /// most 8 groups of about equal size. Each group is titled by its first slide's heading.
    static func slideGroups(_ slides: [Slide]) -> [LectureNotesSection] {
        guard !slides.isEmpty else { return [] }
        var starts = [0]
        for (index, slide) in slides.enumerated() where index > 0 && slide.words <= 12 && !slide.title.isEmpty && slide.figure == nil {
            starts.append(index)
        }
        var groups: [[Slide]] = []
        if (2...10).contains(starts.count) {
            for (offset, start) in starts.enumerated() {
                let end = offset + 1 < starts.count ? starts[offset + 1] : slides.count
                groups.append(Array(slides[start..<end]))
            }
        } else {
            var runs: [[Slide]] = []
            for slide in slides {
                if let last = runs.last?.last, runTitle(last.title) == runTitle(slide.title), !slide.title.isEmpty {
                    runs[runs.count - 1].append(slide)
                } else {
                    runs.append([slide])
                }
            }
            let content = slides.filter { $0.words >= 12 || $0.figure != nil }.count
            let wanted = min(8, max(1, Int((Double(max(content, 1)) / 6).rounded(.up))))
            let size = max(1, Int((Double(slides.count) / Double(wanted)).rounded(.up)))
            for run in runs {
                if let last = groups.last, last.count < size {
                    groups[groups.count - 1] += run
                } else {
                    groups.append(run)
                }
            }
        }
        var sections: [LectureNotesSection] = []
        var used: Set<String> = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            var title = group.first { !$0.title.isEmpty }.map { provisionalTitle($0.title) } ?? "Slides \(first.page)–\(last.page)"
            var key = LectureNotesFormat.sectionKey(topicTitle: title)
            if used.contains(key) {
                title += " (continued)"
                key = LectureNotesFormat.sectionKey(topicTitle: title)
            }
            guard used.insert(key).inserted else { continue }
            sections.append(LectureNotesSection(key: key, title: title, firstPage: first.page, lastPage: last.page))
        }
        return sections
    }

    /// A group's title until the model names it (`NotesValidator.heading`): the first slide's
    /// title up to a page number, a bullet or a footer mark, at most eight words (a PDF without line
    /// breaks gives the slide's whole text as its title).
    static func provisionalTitle(_ title: String) -> String {
        var words: [Substring] = []
        for word in title.split(whereSeparator: \.isWhitespace) {
            if word.allSatisfy(\.isNumber) || word.first.map({ "§•▪◦©|".contains($0) }) == true { break }
            words.append(word)
            if words.count == 8 { break }
        }
        let cut = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: ")?")))
        return cut.isEmpty ? title : cut
    }

    /// A slide title without what repeats it ("(cont.)", "2/3"), folded.
    static func runTitle(_ title: String) -> String {
        let trimmed = title.replacingOccurrences(of: #"\s*(\((cont|contd|continued|fortsetzung|forts)\.?\)|\(?\d+\s*/\s*\d+\)?|\bII+\b)\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return TopicKey.fold(trimmed)
    }

    /// §2.3: 25 words per recorded minute within 900–3,600 (slides only: 40 per content slide, at
    /// most 1,500), times the student's length.
    static func targetWords(source: LectureNotesSource, duration: Double, slides: [Slide], length: NotesLength) -> Int {
        let base: Double
        switch source {
        case .recording: base = min(3_600, max(900, 25 * duration / 60))
        case .slides: base = min(1_500, Double(40 * max(1, slides.filter { $0.words >= 12 || $0.figure != nil }.count)))
        }
        return Int((base * length.factor).rounded())
    }

    /// Each section's share of `total`: by its share of the lecture's time (slides only, or
    /// without times: of its slides), at least 150 words.
    static func budgets(_ sections: [LectureNotesSection], total: Int, end: Double, slides: [Slide]) -> [LectureNotesSection] {
        guard !sections.isEmpty else { return [] }
        var weights: [Double] = sections.indices.map { index in
            let section = sections[index]
            if let start = section.startTime {
                let next = section.endTime ?? sections.dropFirst(index + 1).compactMap(\.startTime).first ?? end
                if next > start { return next - start }
            }
            if let first = section.firstPage { return Double(max(1, (section.lastPage ?? first) - first + 1)) * 60 }
            return 0
        }
        let known = weights.filter { $0 > 0 }
        let fallback = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
        weights = weights.map { $0 > 0 ? $0 : fallback }
        let sum = weights.reduce(0, +)
        return sections.indices.map { index in
            var section = sections[index]
            section.targetWords = max(minimumSectionWords, Int((Double(total) * weights[index] / sum).rounded()))
            return section
        }
    }

    // MARK: - Images

    /// Up to 3 figure slides (a figure line of the study pass, or less text than a read unit
    /// sends as an image), the ones on screen longest first; never the range's first slide.
    static func imagePages(_ slides: [Slide], hasRecording: Bool) -> [Int] {
        let candidates = slides.dropFirst().filter { slide in
            slide.figure != nil || slide.text.trimmingCharacters(in: .whitespacesAndNewlines).count < figureTextLimit
        }
        let ranked = candidates.sorted { lhs, rhs in
            if hasRecording, lhs.lines != rhs.lines { return lhs.lines > rhs.lines }
            if (lhs.figure != nil) != (rhs.figure != nil) { return lhs.figure != nil }
            return lhs.page < rhs.page
        }
        return Array(ranked.prefix(maximumImages).map(\.page)).sorted()
    }

    // MARK: - Earlier lectures

    /// The outlines of the course's earlier done notes, newest lectures first up to 1,500 words,
    /// written in lecture order: "L2 [[3b1f08aa S10]]–S16 · Message ordering: its first sentence."
    static func earlierOutlines(_ lecture: Lecture, in db: Database) throws -> [String] {
        let courseID = lecture.courseID
        let others = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db).filter { other in
            guard other.id != lecture.id else { return false }
            if let number = lecture.number, let theirs = other.number { return theirs < number }
            return (other.heldAt ?? .distantFuture) < (lecture.heldAt ?? .distantPast)
        }.sorted { ($0.number ?? 0, $0.heldAt ?? .distantPast) > ($1.number ?? 0, $1.heldAt ?? .distantPast) }
        var blocks: [(order: Int, lines: [String])] = []
        var words = 0
        for (order, other) in others.enumerated() {
            guard let notes = try LectureNotesRepository.current(lectureID: other.id, in: db), notes.state == .done else { continue }
            let document = LectureNotesFormat.parse(notes.body)
            let name = other.number.map { "L\($0)" } ?? "Lecture"
            var lines = ["\(name) \"\(other.title)\" (lecture \(ChatCitation.key(other.id))):"]
            for section in notes.sections {
                var line = "- \(section.title)"
                if let first = section.firstPage {
                    let last = section.lastPage ?? first
                    line += " · " + ChatCitation.slide(other.id, page: first).marker + (last != first ? "–S\(last)" : "")
                }
                if let part = document.part(section.key), let sentence = firstSentence(of: part) { line += ": " + sentence }
                lines.append(line)
            }
            let count = lines.reduce(0) { $0 + TextRules.wordCount($1) }
            guard words + count <= earlierWordLimit else { break }
            words += count
            blocks.append((order, lines))
        }
        return blocks.sorted { $0.order > $1.order }.flatMap(\.lines)
    }

    /// The first sentence of a section's prose (≤ 25 words), chips left out.
    static func firstSentence(of part: LectureNotesPart) -> String? {
        for case .markdown(let text) in part.blocks {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix(">") && !line.hasPrefix("|") {
                var plain = ""
                for piece in ChatCitation.pieces(of: String(line)) {
                    if case .text(let words) = piece { plain += words }
                }
                plain = PromptText.collapsed(plain)
                guard !plain.isEmpty else { continue }
                let sentence = plain.split(separator: ".", maxSplits: 1).first.map(String.init) ?? plain
                let words = sentence.split(separator: " ")
                return words.prefix(25).joined(separator: " ") + (words.count > 25 ? "…" : ".")
            }
        }
        return nil
    }
}

/// The student's length for lecture notes (`agent_memory.notes_rule`).
public enum NotesRules {
    /// The newest rule for the course, else the newest for all courses, else standard.
    public static func length(memories: [AgentMemory], courseID: Course.ID?) -> NotesLength {
        let rules = memories
            .filter { $0.forgottenAt == nil && $0.kind == .preference && $0.notesRule != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        if let courseID, let own = rules.first(where: { $0.notesRule?.courseID == courseID })?.notesRule { return own.length }
        return rules.first { $0.notesRule?.courseID == nil }?.notesRule?.length ?? .standard
    }
}
