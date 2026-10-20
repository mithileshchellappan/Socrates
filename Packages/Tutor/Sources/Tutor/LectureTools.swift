import Agent
import ClaudeKit
import Foundation
import Search
import StudyCore

/// The read-only lecture tools of the tutor (and of the mail chat, M5): trusted library content,
/// effect `.read`. Every result is compact JSON of at most 4,000 characters (`TutorJSON`), and
/// every row carries its `cite` marker (`[[9a7d94d1 S13]]`, `[[9a7d94d1 37:59]]`) for the model
/// to copy after a claim. A lecture is named by its key, course token + number ("DC 2") or id.
struct LectureTools: Sendable {
    let services: StudyServices
    /// Keyword + semantic retrieval, no planner (the model writes German and English terms itself).
    let search: SearchEngine
    /// False for a sub-agent task that holds web tools: search_lectures never finds the student's
    /// notes and read_slide leaves them out (a fetched page must never reach them).
    var includeNotes = true

    var database: any DatabaseWriter { services.database }

    var all: [AgentTool] { [listLectures, searchLectures, readSlide, readTranscriptSpan, listStudyItems] }

    static let lectureDescription = "The lecture: its key (from a cite or list_lectures), course token and number (\"DC 2\") or id."

    // MARK: list_lectures

    var listLectures: AgentTool {
        AgentTool(
            tool: .custom(
                name: "list_lectures",
                description: "The student's lectures with their keys, titles, days, slide counts and durations.",
                inputSchema: TutorJSON.schema([
                    "course": TutorJSON.nullable(["type": "string", "description": "Course token; null for all courses."]),
                ])
            ),
            effect: .read
        ) { call, _ in
            let library = try await TutorLibrary.load(database)
            var courseID: Course.ID?
            if let reference = call.text("course") {
                guard let course = library.courses.course(reference) else { return .error("Unknown course. Use a token from the course list.") }
                courseID = course.id
            }
            let rows: [JSONValue] = library.lectures.filter { courseID == nil || $0.courseID == courseID }.map { lecture in
                let range = library.slides[lecture.id]
                let recording = library.firstRecording(lecture.id)
                var cite: String?
                if let range {
                    cite = library.slideCite(lecture.id, page: range.firstPage)
                } else if recording != nil {
                    cite = library.momentCite(lecture.id, recording: nil, seconds: 0)
                }
                // mr: the whole deck as its page count; a range of a shared deck as "slides 38–88 of 88".
                var slides: JSONValue = .null
                if let range {
                    slides = range.isWholeDeck ? .int(range.pageCount) : .string("\(range.pagesText) of \(range.pageCount)")
                }
                return [
                    "lecture": .string(library.name(lecture)),
                    "key": .string(ChatCitation.key(lecture.id)),
                    "title": .string(lecture.title),
                    "day": TutorJSON.string(TutorLibrary.day(lecture.heldAt)),
                    "slides": slides,
                    "duration": recording.map { .string(ChatCitation.clock(Int($0.duration))) } ?? .null,
                    "cite": TutorJSON.string(cite),
                ]
            }
            return TutorJSON.fitted([:], key: "lectures", rows: rows)
        }
    }

    // MARK: search_lectures

    var searchLectures: AgentTool {
        AgentTool(
            tool: .custom(
                name: "search_lectures",
                description: """
                    Searches the student's lectures (what was said, the slides, \(includeNotes ? "their notes, " : "")verified \
                    further reading) by words and by meaning. Write the terms in the lecture's language and in English \
                    ("Nachteil Paravirtualisierung paravirtualization drawback").
                    """,
                inputSchema: TutorJSON.schema([
                    "query": ["type": "string", "description": "Search words."],
                    "course": TutorJSON.nullable(["type": "string", "description": "Course token; null for all courses."]),
                    "lecture": TutorJSON.nullable(["type": "string", "description": .string(Self.lectureDescription + " Null for all lectures.")]),
                    "limit": TutorJSON.nullable(["type": "integer", "description": "At most this many hits, 1 to 12 (default 8)."]),
                ])
            ),
            effect: .read
        ) { call, _ in
            guard let text = call.text("query") else { return .error("query is empty.") }
            let library = try await TutorLibrary.load(database)
            var courseID: Course.ID?
            if let reference = call.text("course") {
                guard let course = library.courses.course(reference) else { return .error("Unknown course. Use a token from the course list.") }
                courseID = course.id
            }
            var lectureID: Lecture.ID?
            if let reference = call.text("lecture") {
                guard let lecture = library.lecture(reference) else { return .error("No such lecture. Use a key from list_lectures.") }
                lectureID = lecture.lecture.id
            }
            let limit = min(12, max(1, call.integer("limit") ?? 8))
            let engine = SearchEngine(database: search.database, planner: nil, semantic: search.semantic)
            let scope: SearchQuery.Scope = includeNotes ? .material : .materialWithoutNotes
            let results = try await engine.search(SearchQuery(text, scope: scope, courseID: courseID, lectureID: lectureID, limit: limit))
            let rows: [JSONValue] = results.hits.prefix(limit).compactMap { hit in Self.row(hit, library: library, includeNotes: includeNotes) }
            return TutorJSON.fitted(["query": .string(text)], key: "hits", rows: rows)
        }
    }

    /// One hit as the model reads it: what it is, where (lecture, cite, the slide on screen for a
    /// line) and its text. Mail never comes (scope `.material`); a note only with `includeNotes`.
    static func row(_ hit: SearchHit, library: TutorLibrary, includeNotes: Bool) -> JSONValue? {
        guard let lectureID = hit.lectureID, let lecture = library.lecture(id: lectureID) else { return nil }
        if hit.kind == .note, !includeNotes { return nil }
        var object: JSONObject = [
            "lecture": .string(library.name(lecture)),
            "text": .string(TutorJSON.clip(String(hit.snippet.characters), 300)),
        ]
        let slide = hit.page.map { library.slideCite(lectureID, page: $0) }
        let moment = hit.time.map { library.momentCite(lectureID, recording: hit.recordingID, seconds: $0) }
        switch hit.kind {
        case .transcript:
            object["kind"] = "said"
            object["cite"] = TutorJSON.string(moment)
            object["slide"] = TutorJSON.string(slide)
        case .slide:
            object["kind"] = "slide"
            object["cite"] = TutorJSON.string(slide)
        case .note:
            object["kind"] = "note"
            object["cite"] = TutorJSON.string(slide ?? moment)
            object["title"] = TutorJSON.string(hit.title)
        case .furtherReading:
            object["kind"] = "further_reading"
            object["cite"] = TutorJSON.string(slide)
            object["title"] = TutorJSON.string(hit.title)
        default:
            return nil
        }
        return .object(object)
    }

    // MARK: read_slide

    var readSlide: AgentTool {
        AgentTool(
            tool: .custom(
                name: "read_slide",
                description: "One slide: its text and title, when it was on screen, its summary\(includeNotes ? " and the student's note on it" : "").",
                inputSchema: TutorJSON.schema([
                    "lecture": ["type": "string", "description": .string(Self.lectureDescription)],
                    "slide": ["type": "integer", "description": "Slide number (1-based page of the deck)."],
                ])
            ),
            effect: .read
        ) { call, _ in
            let library = try await TutorLibrary.load(database)
            guard let reference = library.lecture(call.text("lecture")) else { return .error("No such lecture. Use a key from list_lectures.") }
            let lecture = reference.lecture
            guard let range = library.slides[lecture.id] else { return .error("This lecture has no slides.") }
            guard let page = call.integer("slide") else { return .error("slide must be a deck page number.") }
            // mr: only the lecture's own pages of a shared deck.
            guard range.contains(page) else {
                return .error(range.isWholeDeck ? "slide must be 1 to \(range.pageCount)." : "\(library.name(lecture)) shows \(range.pagesText).")
            }
            let lectureID = lecture.id
            let deckID = range.deckID
            let includeNotes = self.includeNotes
            let rows = try await database.read { db in
                (
                    page: try DeckPage.where { $0.deckID.eq(deckID) && $0.pageNumber.eq(page) }.fetchOne(db),
                    visits: try LectureDeckSpan
                        .where { $0.lectureID.eq(lectureID) && $0.startTime.isNot(nil) && $0.firstPage.eq(Int?.some(page)) }
                        .order(by: \.startTime)
                        .fetchAll(db),
                    summaries: try Annotation
                        .where { $0.lectureID.eq(lectureID) && $0.kind.eq(AnnotationKind.summary) && $0.pageNumber.eq(Int?.some(page)) && $0.hiddenAt.is(nil) }
                        .fetchAll(db),
                    notes: try includeNotes
                        ? Note.where { $0.lectureID.eq(lectureID) && $0.pageNumber.eq(Int?.some(page)) }.order(by: \.createdAt).fetchAll(db)
                        : []
                )
            }
            let text = rows.page?.text ?? ""
            let visits: [JSONValue] = rows.visits.prefix(8).map { span in
                [
                    "cite": .string(library.momentCite(lectureID, recording: span.recordingID, seconds: span.startTime ?? 0)),
                    "until": .string(ChatCitation.clock(Int(span.endTime ?? span.startTime ?? 0))),
                ]
            }
            let note = rows.notes.map(\.plainText).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            var object: JSONObject = [
                "lecture": .string(library.name(lecture)),
                "cite": .string(library.slideCite(lectureID, page: page)),
                "title": .string(DeckPage.title(fromPageText: text)),
                "text": .string(TutorJSON.clip(text, 2_000)),
                "visits": .array(visits),
                "summary": TutorJSON.string(rows.summaries.first.map { TutorJSON.clip($0.body, 400) }),
            ]
            if includeNotes { object["note"] = note.isEmpty ? JSONValue.null : .string(TutorJSON.clip(note, 800)) }
            return TutorJSON.object(object)
        }
    }

    // MARK: read_transcript_span

    static let maxSpan: Double = 6 * 60

    var readTranscriptSpan: AgentTool {
        AgentTool(
            tool: .custom(
                name: "read_transcript_span",
                description: """
                    What was said in a lecture between two moments (at most 6 minutes), one line per row with its \
                    cite and the slide on screen. A key with a recording key ("9a7d94d1/b680d175") reads that recording.
                    """,
                inputSchema: TutorJSON.schema([
                    "lecture": ["type": "string", "description": .string(Self.lectureDescription)],
                    "from": ["type": "string", "description": "Start, M:SS or H:MM:SS."],
                    "to": ["type": "string", "description": "End, M:SS or H:MM:SS, at most 6 minutes after from."],
                ])
            ),
            effect: .read
        ) { call, _ in
            let library = try await TutorLibrary.load(database)
            guard let reference = library.lecture(call.text("lecture")) else { return .error("No such lecture. Use a key from list_lectures.") }
            let lectureID = reference.lecture.id
            guard let recording = reference.recording ?? library.firstRecording(lectureID) else {
                return .error("This lecture has no recording.")
            }
            guard let from = Self.seconds(call.text("from")), let requested = Self.seconds(call.text("to")), requested > from else {
                return .error("from and to must be M:SS or H:MM:SS, to after from.")
            }
            let to = min(requested, from + Self.maxSpan, recording.duration + 1)
            let recordingID = recording.id
            let rows = try await database.read { db in
                (
                    lines: try TranscriptSegment
                        .where { $0.recordingID.eq(recordingID) && $0.startTime.lt(to) && $0.endTime.gt(from) }
                        .order(by: \.startTime)
                        .fetchAll(db),
                    spans: try LectureDeckSpan
                        .where { $0.lectureID.eq(lectureID) && $0.recordingID.eq(recordingID) && $0.startTime.isNot(nil) }
                        .order(by: \.startTime)
                        .fetchAll(db)
                )
            }
            let lines: [JSONValue] = rows.lines.map { line in
                let middle = (line.startTime + line.endTime) / 2
                let page = rows.spans.last { ($0.startTime ?? 0) <= middle && middle < ($0.endTime ?? .infinity) }?.firstPage
                return [
                    "cite": .string(library.momentCite(lectureID, recording: recordingID, seconds: line.startTime)),
                    "slide": TutorJSON.string(page.map { library.slideCite(lectureID, page: $0) }),
                    "text": .string(TutorJSON.clip(line.text, 600)),
                ]
            }
            var base: JSONObject = [
                "lecture": .string(library.name(reference.lecture)),
                "from": .string(ChatCitation.clock(Int(from))),
                "to": .string(ChatCitation.clock(Int(to))),
            ]
            if to < requested { base["cut_at"] = .string(ChatCitation.clock(Int(to))) }
            return TutorJSON.fitted(base, key: "lines", rows: lines)
        }
    }

    /// Seconds of "37:59", "1:03:42" or a plain number of seconds.
    static func seconds(_ text: String?) -> Double? {
        guard let text else { return nil }
        if let seconds = ChatCitation.seconds(text[...]) { return Double(seconds) }
        if text.contains(":") {
            // "41:5" or "1:6:15": lenient minutes and seconds.
            let parts = text.split(separator: ":").map { Double($0) }
            guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        return Double(text).flatMap { $0 >= 0 ? $0 : nil }
    }

    // MARK: list_study_items

    /// The study pass's kinds as the tool names them.
    static let studyKinds: [(name: String, kind: AnnotationKind)] = [
        ("exam_hint", .examHint), ("highlight", .highlight), ("said_in_class", .notOnSlides), ("summary", .summary),
        ("topic", .topic), ("further_reading", .furtherReading),
    ]

    var listStudyItems: AgentTool {
        AgentTool(
            tool: .custom(
                name: "list_study_items",
                description: """
                    The study notes made from a lecture: the professor's exam hints and highlights (verbatim), what was \
                    said in class but is not on the slides, slide and lecture summaries, topics and verified further \
                    reading (title, byline, url).
                    """,
                inputSchema: TutorJSON.schema([
                    "lecture": ["type": "string", "description": .string(Self.lectureDescription)],
                    "kinds": TutorJSON.nullable([
                        "type": "array",
                        "items": ["type": "string", "enum": .array(Self.studyKinds.map { .string($0.name) })],
                        "description": "Only these kinds; null for all.",
                    ]),
                ])
            ),
            effect: .read
        ) { call, _ in
            let library = try await TutorLibrary.load(database)
            guard let reference = library.lecture(call.text("lecture")) else { return .error("No such lecture. Use a key from list_lectures.") }
            let lectureID = reference.lecture.id
            let wanted = (call.input["kinds"]?.arrayValue ?? []).compactMap(\.stringValue)
            let kinds = Self.studyKinds.filter { wanted.isEmpty || wanted.contains($0.name) }
            let names = Dictionary(kinds.map { ($0.kind, $0.name) }, uniquingKeysWith: { first, _ in first })
            let kindValues = kinds.map(\.kind)
            let items = try await database.read { db in
                try Annotation
                    .where { $0.lectureID.eq(lectureID) && $0.hiddenAt.is(nil) && $0.kind.in(kindValues) }
                    .fetchAll(db)
            }
            let sorted = items.sorted { lhs, rhs in
                let left = (names[lhs.kind].flatMap { name in Self.studyKinds.firstIndex { $0.name == name } } ?? 0, lhs.startTime ?? -1, lhs.pageNumber ?? 0)
                let right = (names[rhs.kind].flatMap { name in Self.studyKinds.firstIndex { $0.name == name } } ?? 0, rhs.startTime ?? -1, rhs.pageNumber ?? 0)
                return left < right
            }
            let rows: [JSONValue] = sorted.compactMap { item in
                guard let name = names[item.kind] else { return nil }
                var object: JSONObject = ["kind": .string(name)]
                let slide = item.pageNumber.map { library.slideCite(lectureID, page: $0) }
                let moment = item.startTime.map { library.momentCite(lectureID, recording: item.recordingID, seconds: $0) }
                object["cite"] = TutorJSON.string(moment ?? slide)
                object["slide"] = TutorJSON.string(slide)
                if item.kind == .furtherReading {
                    object["title"] = .string(TutorJSON.clip(item.body, 200))
                    object["byline"] = TutorJSON.string(item.detail.map { TutorJSON.clip($0, 120) })
                    object["url"] = TutorJSON.string(item.citations.first { $0.kind == .web && $0.url != nil }?.url?.absoluteString)
                } else {
                    object["text"] = .string(TutorJSON.clip(item.body, 400))
                }
                if item.kind == .notOnSlides, let category = item.category { object["category"] = .string(category.rawValue) }
                return .object(object)
            }
            return TutorJSON.fitted(["lecture": .string(library.name(reference.lecture))], key: "items", rows: rows)
        }
    }
}
