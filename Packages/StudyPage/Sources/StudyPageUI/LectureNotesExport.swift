#if os(macOS)
import Foundation
import ImageIO
import Notes
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// Edit as Note (docs/plan-lecture-notes.md §4): a snapshot of the current notes as a new note in
/// Notes (the course and lecture set) that the student owns. Headings → Heading and Subheading;
/// prose and lists as such; code → paragraphs with the code mark; formulas, diagrams, charts and
/// tables → inline images (`ImageRenderer` at 2×); slides → slide clips; professor quotes → Notes'
/// quote paragraph; chips → slide and time refs; highlights → the note's highlight; kept answers →
/// the question and the answer as paragraphs. Claude's words carry the `ai` mark (grey with one
/// sparkle per block until the student edits them). The copy never updates. nl: Claude's text
/// only: an older version's `note` fences are left out (`LectureNotesFormat.withoutNoteFences`),
/// the student's notes are notes already.
public enum LectureNotesExport {
    /// Writes the note and returns it (nil: the lecture has no notes text).
    @MainActor
    public static func editAsNote(lectureID: Lecture.ID, services: StudyServices) async throws -> Note? {
        let rows = try await services.database.read { db in try LectureNotesRequest(lectureID: lectureID).fetch(db) }
        guard let notes = LectureNotes.current(of: rows.versions), notes.hasText, let lecture = rows.lecture else { return nil }
        var builder = Builder(rows: rows, notes: notes, lecture: lecture, services: services)
        let blocks = try await builder.blocks()
        let note = Note(
            courseID: lecture.courseID, lectureID: lecture.id, blocksJSON: NoteBlock.json(blocks),
            createdAt: services.records.currentDate, updatedAt: services.records.currentDate
        )
        return try await services.records.save(note)
    }

    /// Copy as Markdown (⋯): the source with chips as their labels ("S13", "37:59"), without
    /// `note` fences.
    public static func markdown(_ notes: LectureNotes) -> String {
        LectureNotesText.readable(LectureNotesFormat.withoutNoteFences(notes.body))
    }

    @MainActor
    struct Builder {
        let rows: LectureNotesRows
        let notes: LectureNotes
        let lecture: Lecture
        let services: StudyServices
        var chips: NotesChipResolver

        init(rows: LectureNotesRows, notes: LectureNotes, lecture: Lecture, services: StudyServices) {
            self.rows = rows
            self.notes = notes
            self.lecture = lecture
            self.services = services
            var lectures: [String: NotesDocumentInput.LectureRef] = [:]
            for other in rows.lectures { lectures[ChatCitation.key(other.id)] = .init(id: other.id, number: other.number) }
            var recordings: [String: Recording.ID] = [:]
            for recording in rows.recordings { recordings[ChatCitation.key(recording.id)] = recording.id }
            chips = NotesChipResolver(lectureID: lecture.id, lectures: lectures, recordings: recordings)
        }

        mutating func blocks() async throws -> [NoteBlock] {
            var blocks: [NoteBlock] = []
            let title = lecture.number.map { "Lecture \($0) · \(lecture.title)" } ?? lecture.title
            blocks.append(NoteBlock(type: .heading, text: title, level: 1))
            let document = LectureNotesFormat.parse(LectureNotesFormat.withoutNoteFences(notes.body))
            let titles = Dictionary(notes.sections.map { ($0.key, $0.title) }, uniquingKeysWith: { first, _ in first })
            let marks = rows.marks.filter { $0.removedAt == nil }
            for part in document.parts {
                let partMarks = marks.filter { $0.sectionKey == part.key }
                if part.key != LectureNotesFormat.overviewKey, let heading = titles[part.key] ?? part.heading {
                    blocks.append(NoteBlock(type: .heading, text: heading, level: 2))
                }
                var titleSkipped = part.key == LectureNotesFormat.overviewKey
                for block in part.blocks {
                    switch block {
                    case .markdown(let text):
                        for markdown in MarkdownBlock.blocks(text, alerts: true) {
                            if case .heading(level: 2, text: _) = markdown, !titleSkipped {
                                titleSkipped = true
                                continue
                            }
                            blocks += try await markdownBlocks(markdown, marks: partMarks)
                        }
                    case .fence(let fence):
                        titleSkipped = true
                        blocks += try await fenceBlocks(fence)
                    }
                }
            }
            return blocks
        }

        // MARK: Prose

        private func markdownBlocks(_ block: MarkdownBlock, marks: [LectureNotesMark]) async throws -> [NoteBlock] {
            switch block {
            case .paragraph(let text), .quote(let text), .callout(_, let text):
                let paragraph = NoteBlocks.block(kind: .paragraph, runs: try await inlines(text, marks: marks))
                return [paragraph] + kept(after: paragraph.text, marks: marks)
            case .heading(_, let text):
                return [NoteBlock(type: .heading, text: InlineMarkdown.plainText(text), level: 3)]
            case .list(let items):
                var result: [NoteBlock] = []
                for item in items {
                    let kind: NoteBlock.Kind = item.isNumbered ? .numbered : .bullet
                    let block = NoteBlocks.block(kind: kind, level: item.depth > 0 ? item.depth : nil, runs: try await inlines(item.text, marks: marks))
                    result.append(block)
                    result += kept(after: block.text, marks: marks)
                }
                return result
            case .table(let table):
                return [try await image(TableBlockView(table: table, size: 13), width: 560)].compactMap { $0 }
            case .code(let code, _):
                return codeBlocks(code)
            case .rule:
                return [NoteBlock(type: .divider)]
            }
        }

        /// Runs with the `ai` mark (Claude's words), chips as slide and time refs, formulas as
        /// inline images; the student's highlights as the highlight mark.
        private func inlines(_ text: String, marks: [LectureNotesMark]) async throws -> [NoteInline] {
            var result: [NoteInline] = []
            for run in InlineMarkdown.runs(text) {
                switch run {
                case .text(let words, let style):
                    var runMarks: [NoteInline.Mark] = [.ai]
                    if style.contains(.bold) { runMarks.append(.bold) }
                    if style.contains(.italic) { runMarks.append(.italic) }
                    if style.contains(.code) { runMarks.append(.code) }
                    if style.contains(.strikethrough) { runMarks.append(.strikethrough) }
                    result.append(NoteInline(text: words, marks: runMarks))
                case .citation(let citation):
                    guard let target = chips.target(citation) else { continue }
                    switch target {
                    case .slide(let lecture, let page):
                        let deckID = lecture == self.lecture.id ? rows.deck?.id : nil
                        result.append(NoteMedia.slideRef(deckID: deckID, page: page, lectureID: lecture))
                    case .moment(let lecture, let recording, let seconds):
                        result.append(NoteInline(
                            type: .timeRef, text: TimeText.clock(seconds),
                            source: SourceRef(kind: .transcript, lectureID: lecture, recordingID: recording, time: seconds)
                        ))
                    }
                case .math(let latex):
                    if let media = try await mediaImage(MathImageView(latex: latex, size: 15, display: false), width: nil) {
                        result.append(NoteMedia.inline(media))
                    } else {
                        result.append(NoteInline(text: InlineMath.unicode(latex) ?? latex, marks: [.ai]))
                    }
                }
            }
            return highlighted(result, marks: marks.filter { $0.kind == .highlight })
        }

        /// The highlight mark on the words a highlight covers (found in the paragraph's text).
        private func highlighted(_ runs: [NoteInline], marks: [LectureNotesMark]) -> [NoteInline] {
            let text = runs.map { $0.type == .text ? $0.text : "" }.joined()
            var ranges: [Range<Int>] = []
            for mark in marks {
                guard let found = text.range(of: mark.exact) else { continue }
                let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                ranges.append(lower..<(lower + mark.exact.count))
            }
            guard !ranges.isEmpty else { return runs }
            var result: [NoteInline] = []
            var offset = 0
            for run in runs {
                guard run.type == .text else {
                    result.append(run)
                    continue
                }
                let characters = Array(run.text)
                var piece = ""
                var pieceHighlighted: Bool?
                for (index, character) in characters.enumerated() {
                    let position = offset + index
                    let on = ranges.contains { $0.contains(position) }
                    if pieceHighlighted != nil, pieceHighlighted != on {
                        var copy = run
                        copy.text = piece
                        if pieceHighlighted == true { copy.marks = (copy.marks ?? []) + [.highlight] }
                        result.append(copy)
                        piece = ""
                    }
                    pieceHighlighted = on
                    piece.append(character)
                }
                if !piece.isEmpty {
                    var copy = run
                    copy.text = piece
                    if pieceHighlighted == true { copy.marks = (copy.marks ?? []) + [.highlight] }
                    result.append(copy)
                }
                offset += characters.count
            }
            return result
        }

        /// Kept answers whose passage ends in this paragraph: the question, then the answer.
        private func kept(after text: String, marks: [LectureNotesMark]) -> [NoteBlock] {
            let folded = LectureNotesText.fold(text)
            return marks.filter { $0.kind == .answer && !folded.isEmpty && (" " + folded + " ").contains(" " + LectureNotesText.fold($0.exact) + " ") }
                .flatMap { mark -> [NoteBlock] in
                    var blocks: [NoteBlock] = []
                    if let question = mark.question, !question.isEmpty {
                        blocks.append(NoteBlocks.block(kind: .paragraph, runs: [NoteInline(text: question, marks: [.bold])]))
                    }
                    let answer = InlineMarkdown.plainText(LectureNotesText.readable(mark.answer ?? ""))
                    if !answer.isEmpty {
                        blocks.append(NoteBlocks.block(kind: .paragraph, runs: [NoteInline(text: answer, marks: [.ai])]))
                    }
                    return blocks
                }
        }

        private func codeBlocks(_ code: String) -> [NoteBlock] {
            code.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                NoteBlocks.block(kind: .paragraph, runs: [NoteInline(text: String(line), marks: [.code, .ai])])
            }
        }

        // MARK: Fences

        private func fenceBlocks(_ fence: NotesFence) async throws -> [NoteBlock] {
            guard fence.isClosed else { return [] }
            switch fence.kind {
            case .code:
                return codeBlocks(fence.body)
            case .math:
                let latex = fence.body.trimmingCharacters(in: .whitespacesAndNewlines)
                return [try await image(MathBlockView(latex: latex, size: 17), width: nil)].compactMap { $0 }
            case .diagram:
                guard case .success(let diagram) = Diagram.parse(fence.body) else { return [] }
                return [try await image(DiagramCanvasImage(diagram: diagram), width: nil)].compactMap { $0 }
            case .chart:
                guard case .success(let spec) = ChartSpec.parse(fence.body) else { return [] }
                return [try await image(ChartBlockView(spec: spec, height: 180), width: 520)].compactMap { $0 }
            case .slide:
                guard let ref = NotesSlideRef.parse(fence.body), case .slide(_, let page) = ref.citation, let deck = rows.deck else { return [] }
                let clip = NoteMedia.slideClip(deck: deck, page: page, lectureID: lecture.id, aspectRatio: 16.0 / 9.0, width: 352)
                var blocks = [NoteBlock(type: .paragraph, text: "", inlines: [clip])]
                if !ref.caption.isEmpty { blocks.append(NoteBlocks.block(kind: .paragraph, runs: [NoteInline(text: ref.caption, marks: [.ai])])) }
                return blocks
            case .quote:
                guard let citation = NotesQuoteRef.parse(fence.body), let row = NotesQuoteRef.row(citation, in: rows.quotes) else { return [] }
                let text = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
                return [NoteBlock(
                    type: .quote, text: text,
                    source: SourceRef(kind: .transcript, lectureID: lecture.id, recordingID: row.recordingID, time: row.startTime, quote: text)
                )]
            case .note:
                return []
            case .check:
                let items = NotesCheckItem.parse(fence.body)
                guard !items.isEmpty else { return [] }
                var blocks = [NoteBlock(type: .heading, text: String(localized: "Check yourself"), level: 3)]
                for item in items {
                    blocks.append(NoteBlocks.block(kind: .numbered, runs: [NoteInline(text: InlineMarkdown.plainText(item.question), marks: [.ai])]))
                }
                blocks.append(NoteBlock(type: .heading, text: String(localized: "Answers"), level: 3))
                for item in items {
                    blocks.append(NoteBlocks.block(kind: .numbered, runs: [NoteInline(text: InlineMarkdown.plainText(item.answer), marks: [.ai])]))
                }
                return blocks
            }
        }

        // MARK: Images

        /// A figure as an inline image in a paragraph of its own.
        private func image(_ view: some View, width: CGFloat?) async throws -> NoteBlock? {
            guard let media = try await mediaImage(view, width: width) else { return nil }
            return NoteBlock(type: .paragraph, text: "", inlines: [NoteMedia.inline(media)])
        }

        /// Rendered at 2× on white (legible in a light or dark note), stored as a PNG blob.
        private func mediaImage(_ view: some View, width: CGFloat?) async throws -> NoteAttachment? {
            let content = view
                .padding(width == nil ? 2 : 8)
                .frame(width: width)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.cgImage, let data = Self.png(image) else { return nil }
            let blobs = services.blobs
            return try await Task.detached {
                try NoteMedia.importImage(data: data, fileExtension: "png", blobs: blobs)
            }.value
        }

        /// PNG at 144 dpi, so the note shows it at half its pixel size.
        static func png(_ image: CGImage) -> Data? {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }
    }
}

/// A diagram at its laid-out size (no scrolling) for an image.
struct DiagramCanvasImage: View {
    let diagram: Diagram

    var body: some View {
        let layout = DiagramLayout.layout(diagram)
        DiagramCanvas(layout: layout)
            .frame(width: layout.size.width, height: layout.size.height)
    }
}
#endif
