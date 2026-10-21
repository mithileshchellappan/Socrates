import Foundation
import StudyCore

/// Checks a written version in code (docs/plan-lecture-notes.md §5.4, docs/plan-learn-more.md
/// §4.6) and builds what `finish` stores:
/// - section markers known and in the outline's order (an unknown key whose heading names a
///   missing section is taken as that section; else dropped); a section the model left out keeps
///   its heading; the heading is the section's title;
/// - chips checked against the course's lectures, slide ranges and recording lengths;
/// - `quote` only at an exam hint's or highlight's moment (`NotesQuoteRef.matches`), each row once,
///   at most two highlights a section; every exam hint appears exactly once (code places the
///   missing ones in their section by time, else by slide, before Check yourself); every
///   said-in-class row is cited by its moment (±20 s; slides only, its slide), else code places it
///   there as a bullet with its chip;
/// - nl: no `note` fence (the student's notes show beside the text, in Your notes): any is dropped
///   and none is placed; `LectureNotesSection.noteIDs` is written empty;
/// - `check` parses (at most 3; one per section, last); a `slide` of this lecture's range, one a
///   section, its `box` only on a slide whose image was sent; figures through the figure checker
///   (nil: structural checks), at most two a section and twelve a lecture; open fences dropped;
/// - Check yourself becomes `study_question` rows (origin `notes`, pool `round`).
struct NotesValidator: Sendable {
    let material: NotesMaterial
    let figureCheck: (any NotesFigureChecking)?

    static let figuresPerSection = 2
    static let figuresPerLecture = 12
    static let highlightsPerSection = 2
    static let checksPerSection = 3

    enum Block: Sendable {
        case prose(String)
        case fence(info: String, body: String)
        case dropped
    }

    struct Section: Sendable {
        var outline: LectureNotesSection
        var blocks: [Block] = []
        var checks: [NotesCheckItem] = []
        var quotes: [Annotation.ID] = []
        var slides = 0
        var figures = 0
        var written = false
    }

    /// A figure that failed its check: what the repair call gets.
    struct Problem: Sendable {
        var id: String
        var section: Int
        var block: Int
        var kind: NotesFenceKind
        var info: String
        var body: String
        var problem: String
    }

    struct Draft: Sendable {
        var overview: [String] = []
        var sections: [Section] = []
        var problems: [Problem] = []
        var drops = DropLog()
        var quoted: Set<Annotation.ID> = []
        var figures = 0
    }

    // MARK: - Reading the text

    func draft(_ raw: String) -> Draft {
        var draft = Draft()
        let document = LectureNotesFormat.parse(Self.unwrapped(raw))
        draft.sections = material.sections.map { Section(outline: $0) }
        let index = Dictionary(material.sections.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { first, _ in first })
        if let overview = document.overview {
            for case .markdown(let text) in overview.blocks {
                let cleaned = NotesProse.cleaned(text, chips: material.chips)
                if cleaned.dropped > 0 { draft.drops.drop("chip") }
                // The overview has no heading (a title the model put on top goes).
                let prose = cleaned.text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("#") }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { draft.overview.append(prose) }
            }
            if !overview.fences.isEmpty { draft.drops.drop("overview.fence") }
        }
        for part in document.sections {
            var position = index[part.key]
            if position == nil, let heading = part.heading {
                // A mistyped key: the heading names a section not written yet.
                let wanted = TopicKey.fold(heading)
                position = draft.sections.firstIndex { !$0.written && TopicKey.fold($0.outline.title) == wanted }
            }
            guard let position, !draft.sections[position].written else {
                draft.drops.drop("section.unknown")
                continue
            }
            draft.sections[position].written = true
            // From the slides alone the model names the section (its given title is the first
            // slide's first words, `NotesPrompt.text`).
            if material.source == .slides, let heading = Self.heading(part.heading) {
                draft.sections[position].outline.title = heading
            }
            read(part, into: position, draft: &draft)
        }
        return draft
    }

    /// The model wrapped the whole text in a Markdown fence: unwrapped.
    static func unwrapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), let firstBreak = trimmed.firstIndex(of: "\n") else { return text }
        let info = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<firstBreak].trimmingCharacters(in: .whitespaces).lowercased()
        guard info == "markdown" || info == "md" else { return text }
        var inner = String(trimmed[trimmed.index(after: firstBreak)...])
        if inner.hasSuffix("```") { inner = String(inner.dropLast(3)) }
        return inner
    }

    private func read(_ part: LectureNotesPart, into position: Int, draft: inout Draft) {
        var section = draft.sections[position]
        var headed = false
        for block in part.blocks {
            switch block {
            case .markdown(let text):
                let cleaned = NotesProse.cleaned(text, chips: material.chips)
                if cleaned.dropped > 0 { draft.drops.drop("chip") }
                var prose = cleaned.text
                if !headed {
                    prose = Self.headed(prose, title: section.outline.title)
                    headed = true
                }
                if !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { section.blocks.append(.prose(prose)) }
            case .fence(let fence):
                if !headed {
                    section.blocks.append(.prose("## \(section.outline.title)"))
                    headed = true
                }
                guard fence.isClosed else {
                    draft.drops.drop("fence.open")
                    continue
                }
                switch fence.kind {
                case .slide: slide(fence, section: &section, draft: &draft)
                case .quote: quote(fence, section: &section, draft: &draft)
                // nl: the student's notes are never inside the text.
                case .note: draft.drops.drop("note.inline")
                case .check: check(fence, section: &section, draft: &draft)
                case .math, .diagram, .chart: figure(fence, position: position, section: &section, draft: &draft)
                case .code:
                    if fence.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        draft.drops.drop("code.empty")
                    } else {
                        section.blocks.append(.fence(info: fence.info, body: fence.body))
                    }
                }
            }
        }
        draft.sections[position] = section
    }

    /// A heading the model wrote, as a section title: plain words (emphasis and chips gone),
    /// 2–80 characters; nil otherwise.
    static func heading(_ text: String?) -> String? {
        guard let text else { return nil }
        let plain = text.replacingOccurrences(of: #"\[\[[^\]]*\]\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (2...80).contains(plain.count) ? plain : nil
    }

    /// The section's prose with its title as the one `##` heading at the top.
    static func headed(_ prose: String, title: String) -> String {
        var lines = prose.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if let first = lines.first, first.hasPrefix("# ") || first.hasPrefix("## ") {
            lines[0] = "## \(title)"
        } else {
            lines.insert("## \(title)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Typed fences

    private func slide(_ fence: NotesFence, section: inout Section, draft: inout Draft) {
        guard var reference = NotesSlideRef.parse(fence.body), case .slide(let key, let page) = reference.citation,
              key == material.lectureKey, material.chips.isValid(reference.citation) else {
            draft.drops.drop("slide.range")
            return
        }
        guard section.slides < 1 else {
            draft.drops.drop("slide.cap")
            return
        }
        if reference.box != nil, !material.imagePages.contains(page) {
            reference.box = nil
            draft.drops.drop("slide.box")
        }
        var lines = [reference.citation.marker]
        if let box = reference.box { lines.append(box.line) }
        let caption = NotesProse.cleaned(reference.caption, chips: NotesChips(lectures: [:])).text.trimmingCharacters(in: .whitespaces)
        if !caption.isEmpty { lines.append(caption) }
        section.slides += 1
        section.blocks.append(.fence(info: "slide", body: lines.joined(separator: "\n")))
    }

    private func quote(_ fence: NotesFence, section: inout Section, draft: inout Draft) {
        guard let citation = NotesQuoteRef.parse(fence.body), case .moment(let key, _, let seconds) = citation, key == material.lectureKey,
              let row = material.professor.first(where: { NotesQuoteRef.matches($0, seconds: seconds) && !draft.quoted.contains($0.id) })
        else {
            draft.drops.drop("quote.unbacked")
            return
        }
        if row.kind == .highlight {
            let highlights = section.quotes.filter { id in material.professor.first { $0.id == id }?.kind == .highlight }.count
            guard highlights < Self.highlightsPerSection else {
                draft.drops.drop("quote.cap")
                return
            }
        }
        draft.quoted.insert(row.id)
        section.quotes.append(row.id)
        section.blocks.append(.fence(info: "quote", body: material.moment(row.startTime ?? 0)))
    }

    private func check(_ fence: NotesFence, section: inout Section, draft: inout Draft) {
        guard section.checks.isEmpty else {
            draft.drops.drop("check.second")
            return
        }
        let plain = NotesChips(lectures: [:])
        let items = NotesCheckItem.parse(fence.body).map { item in
            NotesCheckItem(
                question: plain.filtered(item.question).text.trimmingCharacters(in: .whitespaces),
                answer: material.chips.filtered(item.answer).text.trimmingCharacters(in: .whitespaces), format: item.format
            )
        }.filter { !$0.question.isEmpty && !$0.answer.isEmpty }
        guard !items.isEmpty else {
            draft.drops.drop("check.parse")
            return
        }
        section.checks = Array(items.prefix(Self.checksPerSection))
    }

    private func figure(_ fence: NotesFence, position: Int, section: inout Section, draft: inout Draft) {
        guard section.figures < Self.figuresPerSection, draft.figures < Self.figuresPerLecture else {
            draft.drops.drop("figure.cap")
            return
        }
        section.figures += 1
        draft.figures += 1
        section.blocks.append(.fence(info: fence.info, body: fence.body))
        if let problem = problem(in: fence) {
            draft.problems.append(Problem(
                id: "f\(draft.problems.count + 1)", section: position, block: section.blocks.count - 1, kind: fence.kind, info: fence.info,
                body: fence.body, problem: problem
            ))
        }
    }

    /// Why a figure does not render: the app's checker, else the structure alone.
    func problem(in fence: NotesFence) -> String? {
        if let figureCheck { return figureCheck.problem(in: fence) }
        return Self.structuralProblem(fence)
    }

    static let diagramKinds = ["flowchart", "graph", "sequencediagram", "statediagram", "statediagram-v2"]
    static let refusedDiagramWords = ["classdef", "style", "click", "subgraph", "linkstyle"]
    static let chartKinds = ["line", "bar", "scatter", "area", "function"]

    static func structuralProblem(_ fence: NotesFence) -> String? {
        let body = fence.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "\(fence.kind.rawValue): empty" }
        switch fence.kind {
        case .math:
            var depth = 0
            for character in body {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1 }
                if depth < 0 { return "math: unbalanced braces" }
            }
            if depth != 0 { return "math: unbalanced braces" }
            if body.contains("$$") || body.contains("\\begin{document}") { return "math: not math mode only" }
            return nil
        case .diagram:
            let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("%%") }
            let head = lines.first?.split(separator: " ").first.map { $0.lowercased() } ?? ""
            guard diagramKinds.contains(head) else { return "diagram: unknown kind '\(head)'" }
            for (number, line) in lines.enumerated() {
                let word = line.split(separator: " ").first.map { $0.lowercased() } ?? ""
                if refusedDiagramWords.contains(word) { return "diagram: '\(word)' is not supported (line \(number + 1))" }
                if line.contains("<") && line.contains(">") && !line.contains("->") && !line.contains("<-") {
                    return "diagram: HTML in a label (line \(number + 1))"
                }
            }
            if lines.count > 80 { return "diagram: too long" }
            return nil
        case .chart:
            guard let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] else { return "chart: not a JSON object" }
            guard let kind = object["kind"] as? String, chartKinds.contains(kind) else { return "chart: unknown kind" }
            guard object["series"] != nil || object["bars"] != nil || object["functions"] != nil else { return "chart: no data" }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Repairs

    /// Takes the repair call's bodies (by problem id): a body that now passes replaces the block;
    /// a failing block without one, or still failing, is dropped. The number repaired.
    func apply(_ fixes: [String: String], to draft: inout Draft) -> Int {
        var repaired = 0
        for problem in draft.problems {
            if let body = fixes[problem.id], self.problem(in: NotesFence(info: problem.info, body: body)) == nil {
                draft.sections[problem.section].blocks[problem.block] = .fence(info: problem.info, body: body)
                repaired += 1
            } else {
                draft.sections[problem.section].blocks[problem.block] = .dropped
                draft.drops.drop("figure.\(problem.kind.rawValue)")
            }
        }
        draft.problems = []
        return repaired
    }

    // MARK: - Building

    struct Result: Sendable {
        var body: String
        var sections: [LectureNotesSection]
        var questions: [StudyQuestion]
        var drops: DropLog
    }

    /// The checked text, outline and questions; the missing exam hints placed.
    func build(_ draft: Draft, apiCallID: APICall.ID?, now: Date) -> Result {
        var draft = draft
        // Every exam hint once.
        for row in material.professor where row.kind == .examHint && !draft.quoted.contains(row.id) {
            guard let position = sectionIndex(time: row.startTime, page: row.pageNumber, in: draft) else { continue }
            draft.quoted.insert(row.id)
            draft.sections[position].quotes.append(row.id)
            draft.sections[position].blocks.append(.fence(info: "quote", body: material.moment(row.startTime ?? 0)))
            draft.drops.drop("placed.exam_hint")
        }
        // Every said-in-class row: Review shows only the notes once they are written, so a row the
        // text does not cite goes into its section as a bullet with its chip.
        for (position, lines) in missingSaid(in: draft) {
            draft.sections[position].blocks.append(.prose(lines.joined(separator: "\n")))
            for _ in lines { draft.drops.drop("placed.said") }
        }

        var parts: [String] = []
        if !draft.overview.isEmpty { parts.append(draft.overview.joined(separator: "\n\n")) }
        var outline: [LectureNotesSection] = []
        var questions: [StudyQuestion] = []
        for var section in draft.sections {
            // The heading is the first prose block of a written section (`read`); a section left
            // out has none (placed bullets are no heading).
            let hasHeading = section.blocks.contains { block in
                if case .prose(let text) = block { return text.hasPrefix("## ") }
                return false
            }
            if !hasHeading {
                section.blocks.insert(.prose("## \(section.outline.title)"), at: 0)
            }
            var pieces: [String] = []
            for block in section.blocks {
                switch block {
                case .prose(let text): pieces.append(text.trimmingCharacters(in: .newlines))
                case .fence(let info, let body): pieces.append(NotesProse.fence(info, body))
                case .dropped: break
                }
            }
            var entry = section.outline
            entry.questionIDs = []
            if !section.checks.isEmpty {
                let lines = section.checks.map { "Q: \($0.question)\nA: \($0.answer)\nF: \($0.format.rawValue)" }
                pieces.append(NotesProse.fence("check", lines.joined(separator: "\n")))
                for item in section.checks {
                    let question = StudyQuestion(
                        courseID: material.lecture.courseID, lectureID: material.lecture.id, topicID: entry.topicID, topic: entry.title,
                        format: item.format, pool: .round, title: Self.title(of: item.question), prompt: item.question,
                        modelAnswer: item.answer, deckID: entry.firstPage == nil ? nil : material.deck?.id, pageNumber: entry.firstPage,
                        origin: .notes, apiCallID: apiCallID, createdAt: now, updatedAt: now
                    )
                    questions.append(question)
                    entry.questionIDs.append(question.id)
                }
            }
            // nl: the column stays in the schema; the notes are no longer placed in the text.
            entry.noteIDs = []
            entry.quoteIDs = section.quotes
            entry.hasExamHint = section.quotes.contains { id in material.professor.first { $0.id == id }?.kind == .examHint }
            outline.append(entry)
            parts.append(LectureNotesFormat.sectionMarker(entry.key) + "\n" + pieces.joined(separator: "\n\n"))
        }
        return Result(body: parts.joined(separator: "\n\n") + "\n", sections: outline, questions: questions, drops: draft.drops)
    }

    /// How near a moment chip in the text must be to a said-in-class row's time to cite it.
    static let saidWindow: Double = 20

    /// The said-in-class rows the text does not cite, as bullets by section ("- body [[chip]]"):
    /// with a recording a row is cited by a moment chip of this lecture's transcript within 20 s
    /// of its time; slides only, by a chip of its slide. Rows without a time (slides only: without
    /// a slide) and rows whose chip would not be valid are left as they are.
    func missingSaid(in draft: Draft) -> [(Int, [String])] {
        guard !material.said.isEmpty else { return [] }
        var moments: [Int] = []
        var pages: Set<Int> = []
        let prose = draft.overview + draft.sections.flatMap { section in
            section.blocks.compactMap { block -> String? in
                if case .prose(let text) = block { return text }
                return nil
            }
        }
        for text in prose {
            for case .citation(let citation) in ChatCitation.pieces(of: text) {
                switch citation {
                case .moment(let key, let recording, let seconds) where key == material.lectureKey && recording == material.recordingKey:
                    moments.append(seconds)
                case .slide(let key, let page) where key == material.lectureKey:
                    pages.insert(page)
                default:
                    break
                }
            }
        }
        var placed: [Int: [String]] = [:]
        for row in material.said {
            let citation: ChatCitation
            if material.source == .recording {
                guard let start = row.startTime else { continue }
                if moments.contains(where: { abs(Double($0) - start) <= Self.saidWindow }) { continue }
                citation = .moment(lecture: material.lectureKey, recording: material.recordingKey, seconds: max(0, Int(start.rounded(.down))))
            } else {
                guard let page = row.pageNumber else { continue }
                if pages.contains(page) { continue }
                citation = .slide(lecture: material.lectureKey, page: page)
            }
            guard material.chips.isValid(citation) else { continue }
            let body = PromptText.collapsed(NotesProse.cleaned(row.body, chips: material.chips).text)
            guard !body.isEmpty,
                  let position = sectionIndex(time: material.source == .recording ? row.startTime : nil, page: row.pageNumber, in: draft)
            else { continue }
            placed[position, default: []].append("- \(body) \(citation.marker)")
        }
        return placed.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Where a missing exam hint or said-in-class row goes: the section being explained at that time, else the
    /// one whose slides hold the page, else the nearest section before that page.
    func sectionIndex(time: Double?, page: Int?, in draft: Draft) -> Int? {
        let sections = draft.sections.map(\.outline)
        guard !sections.isEmpty else { return nil }
        if let time {
            let timed = sections.enumerated().filter { $0.element.startTime != nil }
            if let found = timed.last(where: { ($0.element.startTime ?? 0) <= time + 1 }) { return found.offset }
            if let first = timed.first { return first.offset }
        }
        if let page {
            if let found = sections.firstIndex(where: { $0.covers(page: page) }) { return found }
            if let before = sections.enumerated().last(where: { ($0.element.firstPage ?? .max) <= page }) { return before.offset }
            return sections.firstIndex { $0.firstPage != nil } ?? 0
        }
        return nil
    }

    /// A question's title: at most 6 of its words.
    static func title(of question: String) -> String {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
        if words.count <= 6 { return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "?.!:")) }
        return words.prefix(6).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;:")) + "…"
    }
}
