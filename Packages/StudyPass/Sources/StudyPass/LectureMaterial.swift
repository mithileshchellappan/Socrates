import Deadlines
import Foundation
import StudyCore

/// Everything the pass reads about one lecture (plan §1), loaded in one read: its main
/// recording's transcript lines in time order ("l1", "l2", …), the slide sections of
/// `LectureOutline`, the deck and its pages, the student's flags, the course.
///
/// One recording and one deck per lecture: the recording with the most lines and the deck with
/// the most timed spans (else the coarse span's). Lines of other recordings are not read.
struct LectureMaterial: Sendable {
    struct Line: Sendable {
        /// "l17": stable while the transcript is.
        var id: String
        var index: Int
        var segment: TranscriptSegment
        /// Index into `sections`.
        var section: Int
        var flagged: Bool

        /// As first transcribed (what read units see; patches are offsets into it).
        var original: String { segment.originalText }
        /// With the corrections applied (what synthesis sees and quotes are found in).
        var text: String { segment.text }
        var start: Double { segment.startTime }
        var end: Double { segment.endTime }
        /// Spoken words (of the original).
        var wordCount: Int { TextRules.wordCount(segment.originalText) }
    }

    struct Section: Sendable {
        var index: Int
        /// Nil for an off-slide stretch or an unaligned transcript.
        var page: Int?
        var title: String
        var start: Double
        var end: Double
        var source: SpanSource?
        var confidence: Double?
        /// Indices into `lines`.
        var lines: [Int]
        var isOffSlide: Bool

        /// An automatic span under 0.4 confidence: no summary for it.
        var isLowConfidence: Bool { source == .auto && (confidence ?? 1) < 0.4 }

        /// `align` attribute of the read prompt.
        var alignLabel: String {
            switch source {
            case .stamp?: "stamp"
            case .manual?: "manual"
            case .auto? where isLowConfidence: "auto-low"
            default: "auto"
            }
        }
    }

    var lecture: Lecture
    var course: Course?
    var recordingID: Recording.ID
    var deck: Deck?
    /// The deck's pages by number.
    var pages: [Int: DeckPage]
    var lines: [Line]
    var sections: [Section]
    /// Pages the lecture covered: its timed sections and its coarse spans of the deck.
    var lecturePages: [Int]
    /// Spoken language (BCP 47): the lecture's, else the course's, else the transcript's.
    var language: String

    /// Slide sections exist (else read units are 15-minute blocks).
    var hasSlides: Bool { sections.contains { $0.page != nil } }
    var isGerman: Bool { language.lowercased().hasPrefix("de") }

    func line(id: String) -> Line? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        guard key.hasPrefix("l"), let number = Int(key.dropFirst()), number >= 1, number <= lines.count else { return nil }
        let line = lines[number - 1]
        return line.id == key ? line : lines.first { $0.id == key }
    }

    func lineIndex(segmentID: TranscriptSegment.ID) -> Int? {
        lines.firstIndex { $0.segment.id == segmentID }
    }

    /// The slide on screen while a line was said (nil off-slide).
    func page(ofLine index: Int) -> Int? {
        sections[lines[index].section].page
    }

    func slideText(_ page: Int) -> String {
        pages[page]?.text ?? ""
    }

    func slideTitle(_ page: Int) -> String {
        DeckPage.title(fromPageText: slideText(page))
    }

    /// Lines as `TranscriptQuote` finds quotes in them (corrected text).
    var quoteLines: [TranscriptQuote.Line] {
        lines.map { TranscriptQuote.Line(id: $0.id, text: $0.text, start: $0.start, words: $0.segment.words ?? []) }
    }

    /// "Data Centers (DC)".
    var courseName: String {
        guard let course else { return "" }
        return course.shortName.isEmpty || course.shortName == course.name ? course.name : "\(course.name) (\(course.shortName))"
    }

    /// "Lecture 2: Virtualization".
    var lectureName: String {
        let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = lecture.number else { return title.isEmpty ? "Lecture" : title }
        return title.isEmpty ? "Lecture \(number)" : "Lecture \(number): \(title)"
    }

    /// The prompt's first line: course, lecture, day, lecturers, spoken language.
    var header: String {
        var parts: [String] = []
        if !courseName.isEmpty { parts.append("Course: \(courseName)") }
        parts.append(lectureName)
        if let held = lecture.heldAt {
            parts.append("held \(held.formatted(.iso8601.year().month().day()))")
        }
        if let professors = course?.professors, !professors.isEmpty {
            parts.append("Lecturers: \(professors.joined(separator: ", "))")
        }
        parts.append("Spoken language: \(language.isEmpty ? "unknown" : language)")
        return PromptText.escape(parts.joined(separator: ". ")) + "."
    }

    /// `header` as the input hash sees it: the lecture and its language. A course rename, a
    /// lecturer or the day never sends a unit again (the prompt still carries them).
    var hashedHeader: String {
        PromptText.escape("\(lectureName). Spoken language: \(language.isEmpty ? "unknown" : language)") + "."
    }

    /// The course's glossary terms that a word of `texts` starts like (folded; the first 5
    /// letters, a shorter term word whole): a glossary edit sends only the blocks it concerns.
    func glossaryTerms(matching texts: [String]) -> [String] {
        let terms = course?.glossaryTerms ?? []
        guard !terms.isEmpty else { return [] }
        var words: Set<String> = []
        var stems: Set<Substring> = []
        for text in texts {
            for word in TextFolding.words(text) {
                words.insert(word)
                if word.count >= 5 { stems.insert(word.prefix(5)) }
            }
        }
        return terms.filter { term in
            TextFolding.words(term).contains { word in
                word.count < 5 ? words.contains(word) : stems.contains(word.prefix(5))
            }
        }
    }

    // MARK: - Loading

    /// Nil when the lecture is gone or has no transcript lines.
    static func load(_ lectureID: Lecture.ID, in db: Database) throws -> LectureMaterial? {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { return nil }
        let course = try Course.find(lecture.courseID).fetchOne(db)
        let segments = try TranscriptSegment
            .where { $0.lectureID.eq(lectureID) }
            .order(by: \.startTime)
            .fetchAll(db)
        var perRecording: [Recording.ID: Int] = [:]
        for segment in segments { perRecording[segment.recordingID, default: 0] += 1 }
        guard let recordingID = perRecording.max(by: { $0.value == $1.value ? $0.key.uuidString > $1.key.uuidString : $0.value < $1.value })?.key
        else { return nil }
        let mainSegments = segments.filter {
            $0.recordingID == recordingID && !$0.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !mainSegments.isEmpty else { return nil }

        let spans = try LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.fetchAll(db)
        var timedPerDeck: [Deck.ID: Int] = [:]
        for span in spans where span.isTimed && span.firstPage != nil && (span.recordingID == nil || span.recordingID == recordingID) {
            timedPerDeck[span.deckID, default: 0] += 1
        }
        let deckID = timedPerDeck.max(by: { $0.value == $1.value ? $0.key.uuidString > $1.key.uuidString : $0.value < $1.value })?.key
            ?? spans.first(where: { !$0.isTimed })?.deckID
        let deck = try deckID.flatMap { try Deck.find($0).fetchOne(db) }
        let deckPages = try deck.map { deck in try DeckPage.where { $0.deckID.eq(deck.id) }.order(by: \.pageNumber).fetchAll(db) } ?? []
        let timed = spans.filter {
            $0.isTimed && $0.deckID == deck?.id && ($0.recordingID == nil || $0.recordingID == recordingID)
        }
        let outline = LectureOutline(segments: mainSegments, spans: timed, pages: deckPages)

        // Lines in time order, ids by position.
        var sectionOfSegment: [TranscriptSegment.ID: Int] = [:]
        for (index, section) in outline.sections.enumerated() {
            for segment in section.segments { sectionOfSegment[segment.id] = index }
        }
        var lines: [Line] = []
        var sections = outline.sections.enumerated().map { index, section in
            Section(
                index: index, page: section.page, title: section.title, start: section.start, end: section.end,
                source: section.source, confidence: section.confidence, lines: [], isOffSlide: section.isOffSlide)
        }
        for segment in mainSegments.sorted(by: { $0.startTime < $1.startTime }) {
            guard let section = sectionOfSegment[segment.id] else { continue }
            let index = lines.count
            lines.append(Line(id: "l\(index + 1)", index: index, segment: segment, section: section, flagged: false))
            sections[section].lines.append(index)
        }
        guard !lines.isEmpty else { return nil }

        // The student's flags (F in class) mark the line said at that moment. Only flags captured
        // in class carry a host time; flags added later in Review stay out of the pass and its hash.
        if let recording = try Recording.find(recordingID).fetchOne(db), recording.sampleRate > 0 {
            let flags = try SlideEvent
                .where { $0.recordingID.eq(recordingID) && $0.kind.eq(SlideEventKind.flag) && $0.hostTime.isNot(nil) }
                .fetchAll(db)
                .compactMap { $0.sampleTime.map { Double($0) / recording.sampleRate } }
            for time in flags {
                let index = lines.lastIndex { $0.start <= time + 0.5 } ?? 0
                lines[index].flagged = true
            }
        }

        var covered = Set(sections.compactMap(\.page))
        for span in spans where !span.isTimed && span.deckID == deck?.id {
            if let first = span.firstPage, let last = span.lastPage, first <= last, last - first < 1_000 {
                covered.formUnion(first...last)
            }
        }
        let pages = Dictionary(deckPages.map { ($0.pageNumber, $0) }, uniquingKeysWith: { first, _ in first })
        covered = covered.filter { pages[$0] != nil || deckPages.isEmpty }

        let language = [lecture.language, course?.language ?? ""].first { !$0.isEmpty }
            ?? outline.languageCounts.first?.language ?? ""
        return LectureMaterial(
            lecture: lecture, course: course, recordingID: recordingID, deck: deck, pages: pages, lines: lines,
            sections: sections, lecturePages: covered.sorted(), language: language)
    }
}
