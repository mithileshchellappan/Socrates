import CryptoKit
import Foundation

// ln: the format of `lecture_notes.body` (docs/plan-lecture-notes.md §2.5, docs/plan-learn-more.md
// §3): Markdown with typed fenced blocks, one source string per version, written by the model and
// streamed as it arrives. This file is the one parser of its structure (the overview and sections,
// fences and their typed bodies) shared by the writer (StudyPass: validation, outline, questions)
// and the renderer (StudyPage: drawing). Prose inside a part (paragraphs, `##`/`###` headings,
// lists, GFM tables, `> [!NOTE]`/`> [!WARNING]` callouts, `**bold**`, `` `code` ``, inline math
// `$…$`, citation markers) is left to the renderer's Markdown parser.
//
// ````text
// One overview paragraph (≤ 90 words) …
//
// <!-- section 4c1e9a2b -->
// ## Vector clocks
// Prose with chips [[9a7d94d1 S24]] …
//
// ```slide
// [[9a7d94d1 S26]]
// box 0.52 0.30 0.40 0.36
// own entry = my events, the others = what I've heard about them
// ```
//
// ```math
// V(a) < V(b) \iff \forall k: V(a)[k] \le V(b)[k] \land V(a) \ne V(b)
// ```
//
// ```diagram
// sequenceDiagram
//   P1->>P2: m1 [2,0,0]
// ```
//
// ```chart
// {"kind":"function", …}            (ChartSpec JSON, StudyPage)
// ```
//
// ```python
// def merge(local, received, me): …
// ```
//
// ```quote
// [[9a7d94d1 56:52]]                 (an exam hint's or highlight's moment: drawn from that row)
// ```
//
// ```note
// [[note 7f3a20c1]]                  (older versions only: where a student's note went; since nl the
// ```                                 notes sit beside the text and this fence is drawn as nothing)
//
// ```check
// Q: P1 holds [3,1,0] and receives [2,4,1]. What is its vector afterwards?
// A: [4,4,1]. The entry-wise maximum is [3,4,1]; then P1 adds one to its own entry.
// F: calculation
// ```
// ````

/// The structure of a lecture notes body.
public enum LectureNotesFormat {
    /// The key of the overview (the text before the first section marker) for marks.
    public static let overviewKey = "overview"

    /// A section's key: the first 8 hex digits of the SHA-256 of the topic's folded title
    /// (`TopicKey.fold`), so it stays the same when the study pass re-runs and replaces the topic rows.
    public static func sectionKey(topicTitle: String) -> String {
        let digest = SHA256.hash(data: Data(TopicKey.fold(topicTitle).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    /// The marker line before a section's heading.
    public static func sectionMarker(_ key: String) -> String {
        "<!-- section \(key) -->"
    }

    /// The overview and the sections of `body`, complete or still streaming: an open fence runs to
    /// the end (`isClosed` false), a half-written marker or comment line at the end is left out.
    public static func parse(_ body: String) -> LectureNotesDocument {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasSuffix("\r") ? line.dropLast() : line
        }
        var parts: [(key: String, lines: [Substring])] = [(overviewKey, [])]
        var fence: Int?
        for (index, line) in lines.enumerated() {
            if let ticks = fence {
                if closesFence(line, ticks: ticks) { fence = nil }
                parts[parts.count - 1].lines.append(line)
                continue
            }
            if let opened = opensFence(line) {
                fence = opened.ticks
                parts[parts.count - 1].lines.append(line)
                continue
            }
            if let key = markerKey(line) {
                parts.append((key, []))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A comment line the stream has not finished yet (or any other comment): never drawn.
            if trimmed.hasPrefix("<!--") && (index == lines.count - 1 || trimmed.hasSuffix("-->")) { continue }
            parts[parts.count - 1].lines.append(line)
        }
        var result: [LectureNotesPart] = []
        for (index, part) in parts.enumerated() {
            let source = part.lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if part.key == overviewKey, source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            result.append(LectureNotesPart(
                key: part.key, source: source, blocks: blocks(of: part.lines), isFollowed: index < parts.count - 1
            ))
        }
        return LectureNotesDocument(parts: result)
    }

    // MARK: Lines

    /// `<!-- section 4c1e9a2b -->` → "4c1e9a2b" (4–16 lower-case hex digits).
    static func markerKey(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else { return nil }
        let inside = trimmed.dropFirst(4).dropLast(3).split(separator: " ", omittingEmptySubsequences: true)
        guard inside.count == 2, inside[0] == "section" else { return nil }
        let key = inside[1]
        guard (4...16).contains(key.count), key.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else { return nil }
        return String(key)
    }

    /// A line opening a fence: up to 3 spaces, at least 3 backticks, then the info string.
    static func opensFence(_ line: Substring) -> (ticks: Int, info: String)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let ticks = rest.prefix { $0 == "`" }.count
        guard ticks >= 3 else { return nil }
        let info = rest.dropFirst(ticks).trimmingCharacters(in: .whitespaces)
        guard !info.contains("`") else { return nil }
        return (ticks, info)
    }

    /// A line closing a fence of `ticks` backticks: up to 3 spaces, at least as many backticks,
    /// nothing else.
    static func closesFence(_ line: Substring, ticks: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix { $0 == "`" }.count
        return count >= ticks && count == trimmed.count && line.prefix(while: { $0 == " " }).count <= 3
    }

    /// `text` (a body or a part's source) without its `note` fences, and without the blank line a
    /// removed fence leaves (nl, docs/plan-notes-layout.md §5: the student's notes sit beside the
    /// text, in Your notes, never inside it; versions written before keep their fences in the body).
    /// Copy as Markdown, Edit as Note and the agent's `read_lecture_notes` carry Claude's text only.
    /// The lines of every other fence stay as they are.
    public static func withoutNoteFences(_ text: String) -> String {
        var lines: [Substring] = []
        var skipping: Int?
        var fence: Int?
        var removed = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let ticks = skipping {
                if closesFence(line, ticks: ticks) {
                    skipping = nil
                    removed = true
                }
                continue
            }
            if removed {
                removed = false
                let blank = line.allSatisfy(\.isWhitespace)
                if blank, lines.last.map({ $0.allSatisfy(\.isWhitespace) }) ?? true { continue }
            }
            if let ticks = fence {
                if closesFence(line, ticks: ticks) { fence = nil }
                lines.append(line)
                continue
            }
            if let opened = opensFence(line) {
                if NotesFenceKind(info: opened.info) == .note {
                    skipping = opened.ticks
                    continue
                }
                fence = opened.ticks
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The prose runs and fences of one part, in order.
    static func blocks(of lines: [Substring]) -> [LectureNotesBlock] {
        var blocks: [LectureNotesBlock] = []
        var prose: [Substring] = []
        var fence: (ticks: Int, info: String, body: [Substring])?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.markdown(text)) }
            prose = []
        }

        for line in lines {
            if let open = fence {
                if closesFence(line, ticks: open.ticks) {
                    blocks.append(.fence(NotesFence(info: open.info, body: open.body.joined(separator: "\n"), isClosed: true)))
                    fence = nil
                } else {
                    fence?.body.append(line)
                }
                continue
            }
            if let opened = opensFence(line) {
                flushProse()
                fence = (opened.ticks, opened.info, [])
                continue
            }
            prose.append(line)
        }
        if let open = fence {
            blocks.append(.fence(NotesFence(info: open.info, body: open.body.joined(separator: "\n"), isClosed: false)))
        }
        flushProse()
        return blocks
    }
}

/// A body split into its overview and sections.
public struct LectureNotesDocument: Hashable, Sendable {
    /// The overview (key `LectureNotesFormat.overviewKey`, when there is text before the first
    /// marker), then the sections in the order written.
    public var parts: [LectureNotesPart]

    public init(parts: [LectureNotesPart]) {
        self.parts = parts
    }

    public var overview: LectureNotesPart? {
        parts.first { $0.key == LectureNotesFormat.overviewKey }
    }

    public var sections: [LectureNotesPart] {
        parts.filter { $0.key != LectureNotesFormat.overviewKey }
    }

    public func part(_ key: String) -> LectureNotesPart? {
        parts.first { $0.key == key }
    }
}

/// The overview or one section of a body.
public struct LectureNotesPart: Hashable, Sendable {
    public var key: String
    /// Its source without the marker line (the heading included).
    public var source: String
    public var blocks: [LectureNotesBlock]
    /// Another marker follows it: while a version streams, a followed part is complete (the last
    /// part is complete only once the version is `done`). Resuming after a pause keeps the
    /// followed parts.
    public var isFollowed: Bool

    public init(key: String, source: String, blocks: [LectureNotesBlock], isFollowed: Bool) {
        self.key = key
        self.source = source
        self.blocks = blocks
        self.isFollowed = isFollowed
    }

    /// The text of its first `## ` heading ("Vector clocks"); nil for the overview or before the
    /// heading has arrived.
    public var heading: String? {
        guard key != LectureNotesFormat.overviewKey else { return nil }
        for case .markdown(let text) in blocks {
            for line in text.split(separator: "\n") where line.hasPrefix("## ") {
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : title
            }
        }
        return nil
    }

    /// Its fences in order.
    public var fences: [NotesFence] {
        blocks.compactMap { block in
            if case .fence(let fence) = block { return fence }
            return nil
        }
    }
}

/// One block of a part.
public enum LectureNotesBlock: Hashable, Sendable {
    /// Prose between fences, for the renderer's Markdown parser.
    case markdown(String)
    case fence(NotesFence)
}

/// A fenced block: its info string, its body and whether its closing fence has arrived (a typed
/// block renders only once closed; until then a placeholder at about its final height).
public struct NotesFence: Hashable, Sendable {
    /// As written after the backticks ("python", "diagram", "slide").
    public var info: String
    public var body: String
    public var isClosed: Bool

    public init(info: String, body: String, isClosed: Bool = true) {
        self.info = info
        self.body = body
        self.isClosed = isClosed
    }

    public var kind: NotesFenceKind { NotesFenceKind(info: info) }

    /// A code block's language ("python"; "" when none was written).
    public var language: String {
        String(info.split(separator: " ").first ?? "").lowercased()
    }
}

/// What a fence is, by its info string's first word.
public enum NotesFenceKind: String, Hashable, Sendable, CaseIterable {
    /// Display math (LaTeX, math mode only).
    case math
    /// A diagram in the Mermaid subset (`diagram` or `mermaid`).
    case diagram
    /// A chart: `ChartSpec` JSON (StudyPage).
    case chart
    /// A slide of the lecture (`NotesSlideRef`).
    case slide
    /// The professor's words, by the moment of an exam hint or highlight row (`NotesQuoteRef`).
    case quote
    /// Where one of the student's notes went (`NotesNoteRef`): older versions only. Since nl the
    /// writer places none, the validator drops any, and the renderer draws one as nothing.
    case note
    /// Check yourself (`NotesCheckItem`).
    case check
    /// Any other info string: code in that language (or none).
    case code

    public init(info: String) {
        switch String(info.split(separator: " ").first ?? "").lowercased() {
        case "math", "latex": self = .math
        case "diagram", "mermaid": self = .diagram
        case "chart": self = .chart
        case "slide": self = .slide
        case "quote": self = .quote
        case "note": self = .note
        case "check": self = .check
        default: self = .code
        }
    }

    /// Validated by the figure checker (and repaired once when it fails).
    public var isFigure: Bool { self == .math || self == .diagram || self == .chart }
}

// MARK: - Typed bodies

/// A `slide` fence: the slide's marker, optionally a box Claude points at (drawn as a faint
/// rounded box in the AI colour over the slide, never as ink: the student's ink stays theirs), and
/// a caption in Claude's words.
public struct NotesSlideRef: Hashable, Sendable {
    /// A `.slide` citation.
    public var citation: ChatCitation
    public var box: NotesSlideBox?
    /// One line in Claude's words under the slide; empty: none.
    public var caption: String

    public init(citation: ChatCitation, box: NotesSlideBox? = nil, caption: String = "") {
        self.citation = citation
        self.box = box
        self.caption = caption
    }

    /// `[[9a7d94d1 S26]]`, then optionally `box x y w h`, then the caption; nil without a slide
    /// marker on the first line.
    public static func parse(_ body: String) -> NotesSlideRef? {
        var lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }[...]
        guard let first = lines.popFirst(), case .citation(let citation)? = ChatCitation.pieces(of: first).first,
              case .slide = citation else { return nil }
        var box: NotesSlideBox?
        if let line = lines.first, line.hasPrefix("box ") {
            box = NotesSlideBox(line: line)
            lines = lines.dropFirst()
        }
        return NotesSlideRef(citation: citation, box: box, caption: lines.joined(separator: " "))
    }
}

/// A rectangle on a slide as fractions of the page (top-left origin): `box 0.52 0.30 0.40 0.36`.
public struct NotesSlideBox: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// "box x y w h"; nil unless all four lie in 0…1 and the box stays on the page.
    public init?(line: String) {
        let numbers = line.split(separator: " ").dropFirst().compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        let (x, y, width, height) = (numbers[0], numbers[1], numbers[2], numbers[3])
        guard x >= 0, y >= 0, width > 0.02, height > 0.02, x + width <= 1.0001, y + height <= 1.0001 else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }

    public var line: String {
        String(format: "box %.2f %.2f %.2f %.2f", x, y, width, height)
    }
}

/// A `quote` fence: the moment of the professor's words. The words are never the model's: the
/// renderer draws the `annotation` row (exam hint or highlight) of that lecture starting at that
/// second (`matches`), and the writer drops a quote no such row backs.
public enum NotesQuoteRef {
    /// The `.moment` citation on the fence's first line.
    public static func parse(_ body: String) -> ChatCitation? {
        let line = body.split(separator: "\n").first.map(String.init) ?? ""
        guard case .citation(let citation)? = ChatCitation.pieces(of: line.trimmingCharacters(in: .whitespaces)).first,
              case .moment = citation else { return nil }
        return citation
    }

    /// Whether `annotation` (an exam hint or highlight) is the row a quote at `seconds` stands for:
    /// its start, rounded down to the second, is that second (± 1 s).
    public static func matches(_ annotation: Annotation, seconds: Int) -> Bool {
        guard annotation.kind == .examHint || annotation.kind == .highlight, let start = annotation.startTime else { return false }
        return abs(Int(start.rounded(.down)) - seconds) <= 1
    }

    /// The row a quote fence stands for (2026-10-21, a lecture's notes cover every recording):
    /// at its second on the chip's recording (`ChatCitation.key` of the row's recording), else at
    /// that second on any (a chip without a recording key: the lecture's first).
    public static func row(_ citation: ChatCitation, in rows: [Annotation]) -> Annotation? {
        guard case .moment(_, let recording, let seconds) = citation else { return nil }
        let found = rows.filter { matches($0, seconds: seconds) }
        guard found.count > 1, let recording else { return found.first }
        return found.first { $0.recordingID.map(ChatCitation.key) == recording } ?? found.first
    }
}

/// A `note` fence: `[[note 7f3a20c1]]`, the first 8 hex digits of a `note` id.
public enum NotesNoteRef {
    public static func parse(_ body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[[note "), trimmed.hasSuffix("]]") else { return nil }
        let key = trimmed.dropFirst(7).dropLast(2).trimmingCharacters(in: .whitespaces)
        guard key.count == 8, key.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else { return nil }
        return key
    }

    public static func marker(_ id: Note.ID) -> String {
        "[[note \(ChatCitation.key(id))]]"
    }
}

/// One Check yourself question of a `check` fence: `Q:` the question, `A:` the answer, `F:` the
/// format (short, explain or calculation; short when missing). A line without a prefix continues
/// the line before it.
public struct NotesCheckItem: Hashable, Sendable {
    public var question: String
    public var answer: String
    public var format: StudyQuestionFormat

    public init(question: String, answer: String, format: StudyQuestionFormat = .short) {
        self.question = question
        self.answer = answer
        self.format = format
    }

    /// The fence's questions in order (only those with a question and an answer).
    public static func parse(_ body: String) -> [NotesCheckItem] {
        var items: [NotesCheckItem] = []
        var current: NotesCheckItem?
        var field = Character("Q")
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let head = line.prefix(2).uppercased()
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            switch head {
            case "Q:":
                if let done = current { items.append(done) }
                current = NotesCheckItem(question: rest, answer: "")
                field = "Q"
            case "A:":
                current?.answer = rest
                field = "A"
            case "F:":
                let format = StudyQuestionFormat(rawValue: rest.lowercased())
                current?.format = [.short, .explain, .calculation].contains(format) ? format : .short
                field = "F"
            default:
                if field == "Q" { current?.question += " " + line }
                if field == "A" { current?.answer += " " + line }
            }
        }
        if let done = current { items.append(done) }
        return items.filter { !$0.question.isEmpty && !$0.answer.isEmpty }
    }
}

// MARK: - Text for marks and copies

/// Plain text of the notes for finding a passage again (marks, keep_notes_answer) and for copies.
/// Matching is on folded words: lower case, diacritics folded, letters and digits only, single
/// spaces; citation markers, inline math and typed fences (all but code) never take part, on
/// either side, so a passage the student selected on screen and the same passage in the Markdown
/// fold alike.
public enum LectureNotesText {
    /// Displayed text (a selection, a mark's `exact`) folded for matching. Attachment characters
    /// (U+FFFC: chips, figures) drop out.
    public static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var words: [String] = []
        var word = ""
        for character in folded {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        return words.joined(separator: " ")
    }

    /// A body's prose and code, folded (markers, inline `$…$` math and typed fences other than
    /// code left out), part by part.
    public static func foldedText(of body: String) -> [(key: String, text: String)] {
        LectureNotesFormat.parse(body).parts.map { part in
            let pieces: [String] = part.blocks.compactMap { block in
                switch block {
                case .markdown(let text): return fold(withoutMarkersAndMath(text))
                case .fence(let fence): return fence.kind == .code ? fold(fence.body) : nil
                }
            }
            return (part.key, pieces.filter { !$0.isEmpty }.joined(separator: " "))
        }
    }

    /// The part of `body` that holds `passage` (folded, at word boundaries): `sectionKey` first,
    /// then any part; nil when the notes do not hold it.
    public static func part(holding passage: String, in body: String, preferring sectionKey: String? = nil) -> String? {
        let needle = fold(passage)
        guard !needle.isEmpty else { return nil }
        let parts = foldedText(of: body)
        let ordered = parts.filter { $0.key == sectionKey } + parts.filter { $0.key != sectionKey }
        return ordered.first { (" " + $0.text + " ").contains(" " + needle + " ") }?.key
    }

    /// Copy as Markdown: the source with markers as their labels ("S13", "37:59"), section markers
    /// and `note` fences left out (nl: the student's notes are not part of Claude's text).
    public static func readable(_ body: String) -> String {
        var lines: [String] = []
        for line in LectureNotesFormat.withoutNoteFences(body).split(separator: "\n", omittingEmptySubsequences: false) {
            if LectureNotesFormat.markerKey(line) != nil { continue }
            lines.append(String(line))
        }
        let text = lines.joined(separator: "\n")
        var result = ""
        for piece in ChatCitation.pieces(of: text) {
            switch piece {
            case .text(let words): result += words
            case .citation(let citation): result += label(citation)
            }
        }
        return result
    }

    /// "S13", "37:59", "p12"; a web page by its host.
    public static func label(_ citation: ChatCitation) -> String {
        switch citation {
        case .slide(_, let page): "S\(page)"
        case .moment(_, _, let seconds): ChatCitation.clock(seconds)
        case .web(let url): url.host() ?? url.absoluteString
        case .change: ""
        case .document(_, let page): page.map { "p\($0)" } ?? ""
        }
    }

    /// Prose without citation markers and inline math.
    static func withoutMarkersAndMath(_ text: String) -> String {
        var plain = ""
        for piece in ChatCitation.pieces(of: text) {
            if case .text(let words) = piece { plain += words }
        }
        return plain.replacingOccurrences(of: #"\$[^$\s][^$]*?[^$\s]\$|\$[^$\s]\$"#, with: " ", options: .regularExpression)
    }
}
