import ClaudeKit
import Foundation
import StudyCore
import StudyUI
import SwiftUI
import Synchronization

// M5 (docs/plan-m5.md §4): the markers in an answer (`ChatCitation`) become chips only after
// code checked them against the rows; anything else is removed from the text and logged with its
// rule. Chips are runs of the answer's one `Text`, links drawn as capsules by
// `AnswerChipRenderer`, so the answer keeps its text layout and inline Markdown.

/// The rows a lecture marker is checked against, read once per conversation on screen.
struct CitationRows: Equatable, Sendable {
    struct LectureRow: Equatable, Sendable {
        var id: Lecture.ID
        var number: Int?
        /// The page count of its deck (the largest when it has several); nil without slides.
        var pageCount: Int?
        /// Oldest first: a marker without a recording key is on the first.
        var recordings: [RecordingRow]
    }

    struct RecordingRow: Equatable, Sendable {
        var id: Recording.ID
        var duration: Double
    }

    /// Lectures by key (`ChatCitation.key`); a key two lectures share names neither.
    var lectures: [String: [LectureRow]] = [:]
    var isLoaded = false

    static func load(_ database: any DatabaseReader) async throws -> CitationRows {
        try await database.read { db in
            let lectures = try Lecture.all.fetchAll(db)
            var spans = try LectureDeckSpan.where { $0.startTime.is(nil) }.fetchAll(db)
            let linked = Set(spans.map(\.lectureID))
            let unlinked = lectures.map(\.id).filter { !linked.contains($0) }
            if !unlinked.isEmpty {
                spans += try LectureDeckSpan.where { $0.lectureID.in(unlinked) }.fetchAll(db)
            }
            let pageCounts = Dictionary(try Deck.all.fetchAll(db).map { ($0.id, $0.pageCount) }, uniquingKeysWith: { max($0, $1) })
            var decks: [Lecture.ID: Int] = [:]
            for span in spans {
                if let count = pageCounts[span.deckID] { decks[span.lectureID] = max(decks[span.lectureID] ?? 0, count) }
            }
            var recordings: [Lecture.ID: [RecordingRow]] = [:]
            let recordingRows = try Recording.where { $0.lectureID.isNot(nil) }.order(by: \.startedAt).fetchAll(db)
            for recording in recordingRows {
                if let lectureID = recording.lectureID {
                    recordings[lectureID, default: []].append(RecordingRow(id: recording.id, duration: recording.duration))
                }
            }
            var rows = CitationRows(isLoaded: true)
            for lecture in lectures {
                rows.lectures[ChatCitation.key(lecture.id), default: []].append(LectureRow(
                    id: lecture.id, number: lecture.number, pageCount: decks[lecture.id], recordings: recordings[lecture.id] ?? []
                ))
            }
            return rows
        }
    }
}

/// A marker that passed the check.
enum CheckedCitation: Hashable, Sendable {
    case slide(lecture: Lecture.ID, number: Int?, page: Int)
    /// `recording` nil: the lecture's first.
    case moment(lecture: Lecture.ID, number: Int?, recording: Recording.ID?, seconds: Int)
    case web(URL)

    var lectureID: Lecture.ID? {
        switch self {
        case .slide(let id, _, _), .moment(let id, _, _, _): id
        case .web: nil
        }
    }
}

/// The checks of docs/plan-m5.md §4, from rows: a lecture marker's key names exactly one lecture,
/// its slide is a page of the lecture's deck, its moment lies in the recording; a web marker's URL
/// (host without `www.`, path without a trailing `/`) is a page a web tool of the same
/// conversation returned (`ChatTranscript.webPages`), and its chip opens the URL as the tool
/// result wrote it, not the marker's.
struct CitationCheck: Sendable {
    let rows: CitationRows
    /// Normalized key → the https URL found in the tool result. Empty in the mail chat.
    let webPages: [String: URL]

    /// Why a marker is not shown (logged once per marker and rule).
    enum Drop: String, Sendable {
        case notLoaded = "rows_not_loaded"
        case unknownLecture = "lecture_unknown"
        case ambiguousLecture = "lecture_ambiguous"
        case noSlides = "slide_no_deck"
        case slideOutsideDeck = "slide_outside_deck"
        case unknownRecording = "moment_unknown_recording"
        case momentOutsideRecording = "moment_outside_recording"
        case pageNotInResults = "web_not_in_tool_results"
        /// ma: a change row marker reaching an answer's text: the agent panel draws these as
        /// change rows before the text is checked; elsewhere (the old chat) they are not shown.
        case changeMarker = "change_marker"
    }

    func check(_ citation: ChatCitation) -> Result<CheckedCitation, DropError> {
        switch citation {
        case .change:
            return .failure(DropError(.changeMarker))
        case .web(let url):
            guard let key = Self.normalized(url), let found = webPages[key] else { return .failure(DropError(.pageNotInResults)) }
            return .success(.web(found))
        case .slide(let key, let page):
            switch lecture(key) {
            case .failure(let drop): return .failure(drop)
            case .success(let lecture):
                guard let pages = lecture.pageCount else { return .failure(DropError(.noSlides)) }
                guard (1...max(1, pages)).contains(page) else { return .failure(DropError(.slideOutsideDeck)) }
                return .success(.slide(lecture: lecture.id, number: lecture.number, page: page))
            }
        case .moment(let key, let recordingKey, let seconds):
            switch lecture(key) {
            case .failure(let drop): return .failure(drop)
            case .success(let lecture):
                let recording: CitationRows.RecordingRow?
                if let recordingKey {
                    let matches = lecture.recordings.filter { ChatCitation.key($0.id) == recordingKey }
                    recording = matches.count == 1 ? matches.first : nil
                } else {
                    recording = lecture.recordings.first
                }
                guard let recording else { return .failure(DropError(.unknownRecording)) }
                guard seconds >= 0, Double(seconds) <= recording.duration + 1 else { return .failure(DropError(.momentOutsideRecording)) }
                let other = recording.id == lecture.recordings.first?.id ? nil : recording.id
                return .success(.moment(lecture: lecture.id, number: lecture.number, recording: other, seconds: seconds))
            }
        }
    }

    struct DropError: Error, Sendable {
        let drop: Drop
        init(_ drop: Drop) { self.drop = drop }
    }

    private func lecture(_ key: String) -> Result<CitationRows.LectureRow, DropError> {
        guard rows.isLoaded else { return .failure(DropError(.notLoaded)) }
        let matches = rows.lectures[key] ?? []
        guard !matches.isEmpty else { return .failure(DropError(.unknownLecture)) }
        guard matches.count == 1, let lecture = matches.first else { return .failure(DropError(.ambiguousLecture)) }
        return .success(lecture)
    }

    // MARK: Web pages

    /// "intel.com/content/www/us/en/…/intel-sdm.html": the host without `www.` (lower case) and
    /// the path without a trailing `/`; the scheme, query and fragment are ignored.
    static func normalized(_ url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path(percentEncoded: true)
        while path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    /// The web pages a tool result names, by normalized key → the URL as written (the first with
    /// that key): every https URL in its strings, or with `urlFieldsOnly` only the string values
    /// of `url` keys (also inside a text that is JSON, as a custom tool's result is). Plain http
    /// is never a source.
    static func webPages(in json: JSONValue, urlFieldsOnly: Bool = false) -> [String: URL] {
        var pages: [String: URL] = [:]
        func add(_ candidate: String) {
            guard let url = URL(string: candidate), url.scheme?.lowercased() == "https", let key = normalized(url), pages[key] == nil else { return }
            pages[key] = url
        }
        func visit(_ value: JSONValue, depth: Int) {
            switch value {
            case .string(let text):
                guard text.contains("http") else { return }
                if urlFieldsOnly {
                    // A text block holding the tool's JSON.
                    guard depth < 4, let parsed = try? JSONValue.parse(text), parsed.objectValue != nil || parsed.arrayValue != nil else { return }
                    visit(parsed, depth: depth + 1)
                } else {
                    urls(in: text).forEach(add)
                }
            case .array(let values):
                values.forEach { visit($0, depth: depth) }
            case .object(let object):
                for (key, value) in object {
                    if urlFieldsOnly, key == "url", case .string(let text) = value {
                        add(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        visit(value, depth: depth)
                    }
                }
            default:
                break
            }
        }
        visit(json, depth: 0)
        return pages
    }

    /// The http(s) URLs in `text`, without trailing punctuation (an unbalanced `)` included).
    static func urls(in text: String) -> [String] {
        var found: [String] = []
        var rest = text[...]
        while let start = rest.range(of: "http") {
            let tail = rest[start.lowerBound...]
            guard tail.hasPrefix("https://") || tail.hasPrefix("http://") else {
                rest = rest[start.upperBound...]
                continue
            }
            let end = tail.firstIndex { $0.isWhitespace || "\"'<>`{}|\\^[]".contains($0) } ?? tail.endIndex
            var candidate = tail[..<end]
            while let last = candidate.last, ".,;:!?)*".contains(last) {
                if last == ")", candidate.filter({ $0 == "(" }).count >= candidate.filter({ $0 == ")" }).count { break }
                candidate = candidate.dropLast()
            }
            found.append(String(candidate))
            rest = tail[end...]
        }
        return found
    }
}

/// An answer ready to draw: Markdown text and checked chips in order, and its Copy text.
struct AnswerText: Equatable {
    enum Style: Hashable, Sendable {
        /// `TimeChip`'s look: accent text on accent soft; plays.
        case time
        /// `SlideChip`'s look: secondary text on the quiet fill; opens the slide.
        case slide
        /// `globe` + the domain, secondary on the quiet fill; opens the page in the browser.
        case web
    }

    struct Chip: Equatable {
        var index: Int
        var label: String
        var style: Style
        var citation: CheckedCitation
    }

    enum Piece: Equatable {
        case text(String)
        case chip(Chip)
    }

    var pieces: [Piece] = []
    var chips: [Chip] = []

    var hasChips: Bool { !chips.isEmpty }

    /// The answer with every marker as its chip's label ("S13", "37:59", "intel.com") and dropped
    /// markers gone.
    var copyText: String {
        pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .chip(let chip): chip.label.replacingOccurrences(of: "\u{00A0}", with: " ")
            }
        }
        .joined()
    }

    /// Checks every marker of `text`. "L2 · " goes before lecture chips only when the answer cites
    /// more than one lecture, or (Review) a lecture other than `openLecture`, the one on screen.
    /// `logs`: dropped markers are logged (once per marker and rule). `prefixes`: decided for the
    /// whole answer when its text is drawn in parts (`AnswerMarkdownView`).
    init(_ text: String, check: CitationCheck?, logs: Bool, openLecture: Lecture.ID? = nil, prefixes forced: Bool? = nil) {
        let raw = ChatCitation.pieces(of: text)
        var checked: [Int: CheckedCitation] = [:]
        if let check {
            for (index, piece) in raw.enumerated() {
                guard let citation = piece.citation else { continue }
                switch check.check(citation) {
                case .success(let result): checked[index] = result
                case .failure(let error):
                    if logs, error.drop != .notLoaded { CitationLog.dropped(citation, rule: error.drop) }
                }
            }
        }
        let lectures = Set(checked.values.compactMap(\.lectureID))
        let prefixes = forced ?? Self.prefixes(lectures: lectures, openLecture: openLecture)
        var pieces: [Piece] = []
        for (index, piece) in raw.enumerated() {
            switch piece {
            case .text(let text):
                if case .text(let previous)? = pieces.last {
                    pieces[pieces.count - 1] = .text(previous + text)
                } else {
                    pieces.append(.text(text))
                }
            case .citation:
                guard let citation = checked[index] else {
                    // Dropped: no gap before punctuation or the end of a line.
                    if case .text(let previous)? = pieces.last, previous.hasSuffix(" ") {
                        let strips: Bool
                        switch index + 1 < raw.count ? raw[index + 1] : nil {
                        case nil: strips = true
                        case .text(let following)?: strips = following.first.map { ".,;:!?)\n ".contains($0) } ?? true
                        case .citation?: strips = false
                        }
                        if strips { pieces[pieces.count - 1] = .text(String(previous.dropLast())) }
                    }
                    continue
                }
                let chip = Chip(index: chips.count, label: Self.label(citation, prefixes: prefixes), style: Self.style(citation), citation: citation)
                chips.append(chip)
                pieces.append(.chip(chip))
            }
        }
        self.pieces = pieces
    }

    /// "L2 · " goes before lecture chips when they cite more than one lecture, or one other than
    /// the lecture on screen.
    static func prefixes(lectures: Set<Lecture.ID>, openLecture: Lecture.ID?) -> Bool {
        lectures.count > 1 || openLecture.map { open in lectures.contains { $0 != open } } ?? false
    }

    static func label(_ citation: CheckedCitation, prefixes: Bool) -> String {
        let nbsp = "\u{00A0}"
        switch citation {
        case .slide(_, let number, let page):
            let slide = "S\(page)"
            guard prefixes, let number else { return slide }
            return "L\(number)\(nbsp)·\(nbsp)\(slide)"
        case .moment(_, let number, _, let seconds):
            let clock = TimeText.clock(Double(seconds))
            guard prefixes, let number else { return clock }
            return "L\(number)\(nbsp)·\(nbsp)\(clock)"
        case .web(let url):
            var host = url.host()?.lowercased() ?? url.absoluteString
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
    }

    static func style(_ citation: CheckedCitation) -> Style {
        switch citation {
        case .slide: .slide
        case .moment: .time
        case .web: .web
        }
    }

    /// Where a chip goes: the lecture at the slide, the lecture playing from the moment, or the page.
    static func destination(_ citation: CheckedCitation) -> StudyDestination? {
        switch citation {
        case .slide(let id, _, let page): .lecture(id, ReviewTarget(page: page))
        case .moment(let id, _, let recording, let seconds):
            .lecture(id, ReviewTarget(time: Double(seconds), plays: true, recordingID: recording))
        case .web: nil
        }
    }

    /// While an answer streams, a marker still being written is left out until it closes.
    static func withoutOpenMarker(_ text: String) -> String {
        guard let open = text.range(of: "[[", options: .backwards), !text[open.upperBound...].contains("]]") else { return text }
        return String(text[..<open.lowerBound])
    }

    // MARK: Drawing

    /// The lecture chips' link scheme: "studyportal-cite://slide/<lecture>/13",
    /// "studyportal-cite://moment/<lecture>/<recording or ->/2279". A web chip links its page.
    static let linkScheme = "studyportal-cite"

    static func link(_ citation: CheckedCitation) -> URL? {
        switch citation {
        case .slide(let id, _, let page):
            URL(string: "\(linkScheme)://slide/\(id.uuidString.lowercased())/\(page)")
        case .moment(let id, _, let recording, let seconds):
            URL(string: "\(linkScheme)://moment/\(id.uuidString.lowercased())/\(recording?.uuidString.lowercased() ?? "-")/\(seconds)")
        case .web(let url):
            url
        }
    }

    /// Where a lecture chip's link goes (nil for anything else).
    static func destination(link url: URL) -> StudyDestination? {
        guard url.scheme == linkScheme, let kind = url.host() else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        switch kind {
        case "slide":
            guard parts.count == 2, let id = UUID(uuidString: parts[0]), let page = Int(parts[1]) else { return nil }
            return destination(.slide(lecture: id, number: nil, page: page))
        case "moment":
            guard parts.count == 3, let id = UUID(uuidString: parts[0]), let seconds = Int(parts[2]) else { return nil }
            return destination(.moment(lecture: id, number: nil, recording: UUID(uuidString: parts[1]), seconds: seconds))
        default:
            return nil
        }
    }

    /// The answer as one `Text`: one sparkle, then the Markdown runs (links removed: only checked
    /// chips link) and the chips as link runs for `AnswerChipRenderer`. ma: `sparkle` false for a
    /// paragraph after the answer's first block (one sparkle per answer).
    func text(sparkle: Bool = true) -> Text {
        var result = sparkle ? Text("\(Text(Image(systemName: "sparkle")).foregroundStyle(Color.ai)) ") : Text(verbatim: "")
        for piece in pieces {
            switch piece {
            case .text(let text):
                result = Text("\(result)\(Text(Self.markdown(text)))")
            case .chip(let chip):
                result = Text("\(result)\(Self.chipText(chip))")
            }
        }
        return result
    }

    static func chipText(_ chip: Chip) -> Text {
        let nbsp = "\u{00A0}"
        var label = AttributedString(nbsp + chip.label + nbsp)
        label.link = link(chip.citation)
        let run = ChipRun(index: chip.index, style: chip.style)
        switch chip.style {
        case .web:
            var glyph = AttributedString(nbsp)
            glyph.link = label.link
            return Text("\(Text(glyph))\(Text(Image(systemName: "globe")))\(Text(label))")
                .font(.system(size: 10.5))
                .baselineOffset(1)
                .customAttribute(run)
        case .time, .slide:
            return Text(label)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .baselineOffset(1)
                .customAttribute(run)
        }
    }

    /// Inline Markdown (bold, italics, code), whitespace kept; links are removed, so nothing in an
    /// answer links except its checked chips.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let linked = string.runs.filter { $0.link != nil }.map(\.range)
        for range in linked {
            string[range].link = nil
        }
        return string
    }
}

/// Marks a chip's runs (its label, and for a web chip the globe) for `AnswerChipRenderer`.
struct ChipRun: TextAttribute {
    var index: Int
    var style: AnswerText.Style
}

/// Draws each chip as a capsule behind its runs (one per chip and line), its glyphs in the chip's
/// colour, then the rest of the text as laid out.
struct AnswerChipRenderer: TextRenderer {
    let colorScheme: ColorScheme

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var capsules: [Int: (rect: CGRect, style: AnswerText.Style)] = [:]
            for run in line {
                guard let chip = run[ChipRun.self] else { continue }
                let rect = run.typographicBounds.rect
                capsules[chip.index] = (capsules[chip.index].map { $0.rect.union(rect) } ?? rect, chip.style)
            }
            for (_, capsule) in capsules.sorted(by: { $0.key < $1.key }) {
                let rect = capsule.rect.insetBy(dx: 0, dy: -1)
                context.fill(Capsule().path(in: rect), with: background(capsule.style))
            }
            for run in line {
                guard let chip = run[ChipRun.self] else {
                    context.draw(run)
                    continue
                }
                let bounds = run.typographicBounds.rect.insetBy(dx: -2, dy: -3)
                let ink = foreground(chip.style)
                context.drawLayer { layer in
                    layer.clipToLayer { mask in mask.draw(run) }
                    layer.fill(Path(bounds), with: ink)
                }
            }
        }
    }

    private func background(_ style: AnswerText.Style) -> GraphicsContext.Shading {
        switch style {
        case .time: .color(Color.accentSoft(colorScheme))
        case .slide, .web: .color(Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(colorScheme == .dark ? 0.20 : 0.10))
        }
    }

    private func foreground(_ style: AnswerText.Style) -> GraphicsContext.Shading {
        switch style {
        case .time: .color(.accentColor)
        case .slide, .web: .color(.secondary)
        }
    }
}

/// Logs a dropped marker once per marker and rule (an answer is checked again on every redraw).
enum CitationLog {
    private static let logged = Mutex<Set<String>>([])

    static func dropped(_ citation: ChatCitation, rule: CitationCheck.Drop) {
        let key = citation.marker + " " + rule.rawValue
        let isNew = logged.withLock { $0.insert(key).inserted }
        guard isNew else { return }
        ChatUILog.ui.notice("Citation dropped (\(rule.rawValue, privacy: .public)): \(citation.marker, privacy: .private)")
    }
}
