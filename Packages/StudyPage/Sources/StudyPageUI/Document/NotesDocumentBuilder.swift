#if os(macOS)
import AppKit
import NotesUI
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// What the document's attachments ask of the view around them.
@MainActor
protocol NotesDocumentActions: NotesSizeObserver {
    var services: StudyServices? { get }
    func open(_ target: NotesChipTarget)
    func toggleAnswers(_ key: String)
    func writeAgain()
    func keptAnswerHovered(_ mark: LectureNotesMark.ID, _ hovered: Bool)
    func removeKept(_ mark: LectureNotesMark)
    func continueInChat(_ mark: LectureNotesMark)
}

/// One paragraph of the document (with its newline) and what it is drawn from: a unit whose
/// signature did not change keeps its text and attachments when the document is drawn again,
/// so streaming never rebuilds what is already on screen.
struct NotesUnit {
    var signature: String
    var text: NSAttributedString
    var section: String
    var role: NotesRole
}

/// The built document.
struct NotesBuild {
    var units: [NotesUnit] = []
    /// The student's highlights (document ranges, merged where they overlap when drawn).
    var highlights: [(id: LectureNotesMark.ID, range: NSRange)] = []
    /// Kept answers' passages (document ranges): hovering the answer marks its passage.
    var passages: [LectureNotesMark.ID: NSRange] = [:]
    /// Marks found again in this version, and those not found (written back once the version is
    /// done: `setOrphaned`).
    var found: Set<LectureNotesMark.ID> = []
    var orphaned: Set<LectureNotesMark.ID> = []
}

/// The notes as one read-only TextKit document (docs/plan-lecture-notes.md §2, docs/plan-notes-
/// layout.md §3): the overview with the document's one sparkle, then one section per topic
/// (heading with its chip and the amber star, Claude's prose in grey with primary emphasis,
/// figures, the professor's quotes, Check yourself), the student's highlights and kept answers.
/// The student's own notes are not drawn in it (nl: they are beside it, in Your notes; an older
/// version's `note` fence draws as nothing). Paragraphs are built without the page's prose inset
/// (`.notesBaseStyle`); the coordinator indents them (`NotesIndent`), so a width change never
/// builds anything again. Code, tables, diagrams, charts and slides break out to the full width.
@MainActor
final class NotesDocumentBuilder {
    let input: NotesDocumentInput
    let metrics: NotesMetrics
    weak var actions: (any NotesDocumentActions)?
    /// Marks already found in an unchanged section text (kept by the view across builds).
    let anchors: NotesAnchorCache
    /// The body and Markdown already parsed (a zoom or appearance change parses nothing again).
    let parsed: NotesParseCache
    /// The page's inset, for blocks at the measure.
    let measure: NotesLayoutBox
    /// Changes everything (style, appearance, zoom): part of every signature.
    let stamp: String

    private var dark: Bool { input.isDark }
    private var labelInk: NSColor { NotesNSInk.label(dark) }
    private var greyInk: NSColor { NotesNSInk.secondary(dark) }

    init(
        input: NotesDocumentInput, actions: any NotesDocumentActions, anchors: NotesAnchorCache, parsed: NotesParseCache,
        measure: NotesLayoutBox
    ) {
        self.input = input
        metrics = NotesMetrics(style: input.style, zoom: input.zoom)
        self.actions = actions
        self.anchors = anchors
        self.parsed = parsed
        self.measure = measure
        stamp = "\(input.style)|\(input.isDark)|\(input.zoom)"
    }

    private func scaled(_ points: CGFloat) -> CGFloat { metrics.scaled(points) }

    // MARK: The document

    func build() -> NotesBuild {
        var build = NotesBuild()
        guard let notes = input.notes, notes.hasText else {
            build.units = placeholderDocument()
            return build
        }
        let document = parsed.document(notes.body)
        let writing = notes.state == .generating || notes.state == .paused || notes.state == .queued
        let lastKey = document.parts.last?.key
        var sectionsUnits: [(key: String, heading: [NotesUnit], body: [NotesUnit])] = []

        if let overview = document.overview {
            var body = partUnits(overview, sectionKey: LectureNotesFormat.overviewKey, sparkle: true)
            if writing, lastKey == LectureNotesFormat.overviewKey { body += writingTail(notes, partial: true) }
            sectionsUnits.append((LectureNotesFormat.overviewKey, [], body))
        }
        var seen: Set<String> = []
        let outline = input.outline
        for section in outline {
            seen.insert(section.key)
            let part = document.part(section.key)
            let heading = [headingUnit(section, title: section.title)]
            if input.folded.contains(section.key) {
                sectionsUnits.append((section.key, heading, []))
                continue
            }
            var body: [NotesUnit] = []
            if let part {
                body = partUnits(part, sectionKey: section.key, sparkle: false)
                if writing, lastKey == section.key { body += writingTail(notes, partial: true) }
            } else if writing {
                body = [skeletonUnit(section.key, widths: Self.skeleton(for: section.key))]
            }
            sectionsUnits.append((section.key, heading, body))
        }
        // Sections the outline does not know (written all the same), in the order written.
        for part in document.sections where !seen.contains(part.key) {
            let title = part.heading ?? ""
            let section = LectureNotesSection(key: part.key, title: title)
            let heading = title.isEmpty ? [] : [headingUnit(section, title: title)]
            var body = input.folded.contains(part.key) ? [] : partUnits(part, sectionKey: part.key, sparkle: false)
            if writing, lastKey == part.key, !input.folded.contains(part.key) { body += writingTail(notes, partial: true) }
            sectionsUnits.append((part.key, heading, body))
        }
        if notes.state == .failed {
            let key = sectionsUnits.last?.key ?? LectureNotesFormat.overviewKey
            sectionsUnits.append((key, [], [failureUnit(notes, sectionKey: key)]))
        }

        // Marks: anchored in their section's text, kept answers under the paragraph where their
        // passage ends, orphans at their section's end with the passage quoted.
        let marks = input.marks.filter { $0.removedAt == nil }
        let isSettled = notes.state == .done || notes.state == .failed
        var offset = 0
        var leftover = marks.filter { mark in
            !sectionsUnits.contains { $0.key == mark.sectionKey && !input.folded.contains(mark.sectionKey) }
                && !input.folded.contains(mark.sectionKey)
        }
        if !isSettled { leftover = [] }
        for entry in sectionsUnits {
            build.units += entry.heading
            offset += entry.heading.reduce(0) { $0 + $1.text.length }
            var body = entry.body
            // A folded section's marks wait (neither drawn nor orphaned).
            let sectionMarks = input.folded.contains(entry.key) ? [] : marks.filter { $0.sectionKey == entry.key }
            let text = body.map { $0.role == .chrome ? String(repeating: " ", count: $0.text.length) : $0.text.string }.joined()
            var starts: [Int] = []
            var cursor = 0
            for unit in body {
                starts.append(cursor)
                cursor += unit.text.length
            }
            // Kept answers to insert after a unit (by unit index), in the order kept.
            var after: [Int: [NotesUnit]] = [:]
            var tail: [NotesUnit] = []
            var highlightLocal: [(LectureNotesMark.ID, NSRange)] = []
            for mark in sectionMarks.sorted(by: { $0.createdAt < $1.createdAt }) {
                // The fuzzy step waits until the version is settled (never at every streamed update).
                let range = body.isEmpty ? nil : anchors.locate(mark, in: text, fuzzy: isSettled)
                if let range {
                    build.found.insert(mark.id)
                    switch mark.kind {
                    case .highlight:
                        highlightLocal.append((mark.id, range))
                    case .answer:
                        let end = max(range.location, NSMaxRange(range) - 1)
                        let index = starts.lastIndex { $0 <= end } ?? max(0, body.count - 1)
                        after[index, default: []].append(keptUnit(mark, sectionKey: entry.key, orphaned: false))
                        build.passages[mark.id] = range
                    }
                } else if !body.isEmpty || isSettled {
                    if isSettled { build.orphaned.insert(mark.id) }
                    // A highlight hides; a kept answer goes to the section's end with its passage.
                    if mark.kind == .answer, isSettled { tail.append(keptUnit(mark, sectionKey: entry.key, orphaned: true)) }
                }
            }
            // Highlights become the units' own background (part of their signature).
            var shift = 0
            var inserted: [NotesUnit] = []
            for (index, unit) in body.enumerated() {
                let start = starts[index]
                let length = unit.text.length
                let ranges = highlightLocal.compactMap { id, range -> (LectureNotesMark.ID, NSRange)? in
                    let clipped = NSIntersectionRange(range, NSRange(location: start, length: length))
                    guard clipped.length > 0 else { return nil }
                    return (id, NSRange(location: clipped.location - start, length: clipped.length))
                }
                var unit = unit
                if !ranges.isEmpty, unit.role != .chrome {
                    let text = NSMutableAttributedString(attributedString: unit.text)
                    for (_, range) in ranges {
                        text.enumerateAttribute(.attachment, in: range) { value, sub, _ in
                            if value == nil { text.addAttribute(.backgroundColor, value: NotesNSInk.highlighter(dark), range: sub) }
                        }
                    }
                    unit.text = text
                    unit.signature += "|hl" + ranges.map { "\($0.1.location):\($0.1.length)" }.joined(separator: ",")
                }
                for (id, range) in ranges {
                    build.highlights.append((id, NSRange(location: offset + shift + start + range.location, length: range.length)))
                }
                inserted.append(unit)
                for kept in after[index] ?? [] {
                    inserted.append(kept)
                    shift += kept.text.length
                }
            }
            // Passages' document ranges (after the kept answers before them).
            for (id, range) in build.passages where sectionMarks.contains(where: { $0.id == id }) {
                let before = after.filter { index, _ in starts.indices.contains(index) && starts[index] + body[index].text.length <= range.location }
                    .values.flatMap { $0 }.reduce(0) { $0 + $1.text.length }
                build.passages[id] = NSRange(location: offset + range.location + before, length: range.length)
            }
            body = inserted + tail
            build.units += body
            offset += body.reduce(0) { $0 + $1.text.length }
        }
        for mark in leftover where mark.kind == .answer {
            build.orphaned.insert(mark.id)
            let unit = keptUnit(mark, sectionKey: mark.sectionKey, orphaned: true)
            build.units.append(unit)
        }
        return build
    }

    /// Before the text: the outline's headings over skeleton lines while queued, writing or paused.
    /// No Claude Code, or a version that failed before its first words: the headings and one line
    /// saying why (failed: the triangle and Write Again…). No version at all (nothing to write
    /// from yet): nothing, never a skeleton that waits forever.
    private func placeholderDocument() -> [NotesUnit] {
        var units: [NotesUnit] = []
        let outline = input.outline
        if let sentence = input.unavailable {
            units = outline.map { headingUnit($0, title: $0.title) }
            units.append(lineUnit(sentence, sectionKey: outline.last?.key ?? LectureNotesFormat.overviewKey))
            return units
        }
        guard let notes = input.notes else { return [] }
        if notes.state == .failed || notes.state == .done || notes.state == .cancelled {
            units = outline.map { headingUnit($0, title: $0.title) }
            units.append(failureUnit(notes, sectionKey: outline.last?.key ?? LectureNotesFormat.overviewKey))
            return units
        }
        if notes.state == .paused {
            units.append(progressUnit(notes, sectionKey: LectureNotesFormat.overviewKey))
        }
        units.append(skeletonUnit(LectureNotesFormat.overviewKey, widths: [0.96, 0.88, 0.58]))
        for section in outline {
            units.append(headingUnit(section, title: section.title))
            units.append(skeletonUnit(section.key, widths: Self.skeleton(for: section.key)))
        }
        if outline.isEmpty {
            units.append(skeletonUnit(LectureNotesFormat.overviewKey, widths: [0.94, 0.82, 0.5]))
        }
        return units
    }

    /// After the text written so far: the one writing line (or "Paused until 17:20") and two
    /// skeleton lines.
    private func writingTail(_ notes: LectureNotes, partial: Bool) -> [NotesUnit] {
        [progressUnit(notes, sectionKey: "tail"), skeletonUnit("tail", widths: [0.94, 0.62])]
    }

    static func skeleton(for key: String) -> [CGFloat] {
        let variants: [[CGFloat]] = [[0.96, 0.88, 0.54], [0.95, 0.70], [0.92, 0.84, 0.60], [0.90, 0.66]]
        return variants[key.utf8.reduce(0) { $0 + Int($1) } % variants.count]
    }

    // MARK: Units

    private func paragraphStyle(spacingBefore: CGFloat = 0, spacing: CGFloat? = nil, font: NSFont, lineHeight: CGFloat? = nil) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        let natural = font.ascender - font.descender + font.leading
        style.lineSpacing = max(0, (lineHeight ?? metrics.lineHeight) - natural)
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing ?? metrics.paragraphSpacing
        return style
    }

    private var bodyFont: NSFont { NSFont.systemFont(ofSize: metrics.body) }

    /// A paragraph's attributes. Its style is the base style the page's inset is added to
    /// (`NotesIndent`); a breakout (`atMeasure` false) keeps its style as it is, the full width.
    private func base(
        _ sectionKey: String, role: NotesRole, font: NSFont? = nil, color: NSColor? = nil, style: NSParagraphStyle? = nil, atMeasure: Bool = true
    ) -> [NSAttributedString.Key: Any] {
        let font = font ?? bodyFont
        let style = style ?? paragraphStyle(font: font)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color ?? greyInk,
            .paragraphStyle: style,
            .notesSection: sectionKey,
            .notesRole: role.rawValue
        ]
        if atMeasure { attributes[.notesBaseStyle] = style }
        return attributes
    }

    private func unit(_ signature: String, _ text: NSAttributedString, section: String, role: NotesRole) -> NotesUnit {
        let full = NSMutableAttributedString(attributedString: text)
        var newline = text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]
        newline[.attachment] = nil
        newline[.link] = nil
        newline[.backgroundColor] = nil
        full.append(NSAttributedString(string: "\n", attributes: newline))
        return NotesUnit(signature: stamp + "|" + signature, text: full, section: section, role: role)
    }

    /// A section heading: its title (15 semibold, primary), the amber star when the section holds a
    /// verified exam hint, its one chip at the line's end (a moment, else its first slide).
    func headingUnit(_ section: LectureNotesSection, title: String) -> NotesUnit {
        let font = NSFont.systemFont(ofSize: metrics.sectionHeading, weight: .semibold)
        let style = paragraphStyle(
            spacingBefore: metrics.sectionSpacingBefore - metrics.paragraphSpacing, spacing: scaled(8), font: font, lineHeight: font.pointSize + scaled(5)
        )
        // The chip's tab is set at the measure's end with the inset (`NotesIndent`).
        style.tailIndent = 0
        var attributes = base(section.key, role: .heading, font: font, color: labelInk, style: style)
        attributes[.notesHeading] = section.key
        let text = NSMutableAttributedString(string: title, attributes: attributes)
        if section.hasExamHint, let star = ImageAttachment.symbol("star", size: metrics.sectionHeading - scaled(3), weight: .semibold, color: NotesNSInk.professor(dark)) {
            text.append(NSAttributedString(string: " ", attributes: attributes))
            text.append(ImageAttachment.string(star, baseline: -scaled(1), plainText: "", attributes: attributes))
        }
        var chipSignature = ""
        if let chip = headingChip(section) {
            text.append(NSAttributedString(string: "\t", attributes: attributes))
            var chipAttributes = attributes
            chipAttributes[.attachment] = chip.attachment.attachment()
            text.append(NSAttributedString(string: "\u{FFFC}", attributes: chipAttributes))
            chipSignature = chip.signature
        }
        let folded = input.folded.contains(section.key)
        return unit("h|\(section.key)|\(title)|\(section.hasExamHint)|\(chipSignature)|\(folded)", text, section: section.key, role: .heading)
    }

    private func headingChip(_ section: LectureNotesSection) -> (attachment: NotesAttachment, signature: String)? {
        let lecture = input.lectureID
        if input.hasRecording, let start = section.startTime {
            // On the section's own recording (nil: the lecture's first).
            let target = NotesChipTarget.moment(lecture: lecture, recording: section.recordingID, seconds: start)
            return (chipAttachment(target), "t\(section.recordingID.map(ChatCitation.key) ?? "")\(Int(start))")
        }
        if let page = section.firstPage {
            return (chipAttachment(.slide(lecture: lecture, page: page)), "s\(page)")
        }
        return nil
    }

    /// A chip: a moment (play glyph, accent) or a slide ("S13"; "L2 · S14" for another lecture's),
    /// at the zoom's size.
    private func chipAttachment(_ target: NotesChipTarget) -> NotesAttachment {
        let actions = actions
        let size = metrics.chip
        switch target {
        case .slide(let lecture, let page):
            let prefix = lecture == input.lectureID ? nil : input.lectures.values.first { $0.id == lecture }?.number.map { "L\($0)" }
            let text = prefix.map { "\($0) · S\(page)" } ?? "S\(page)"
            return InlineViewAttachment(
                NotesChip(text: text, size: size) { actions?.open(target) }, plainText: text, baseline: -scaled(3.5)
            )
        case .moment(_, _, let seconds):
            let prefix = target.lectureID == input.lectureID ? nil : input.lectures.values.first { $0.id == target.lectureID }?.number.map { "L\($0)" }
            let text = prefix.map { "\($0) · \(TimeText.clock(seconds))" } ?? TimeText.clock(seconds)
            return InlineViewAttachment(
                NotesChip(text: text, kind: .moment, size: size) { actions?.open(target) }, plainText: text, baseline: -scaled(3.5)
            )
        case .material(_, _, let label, let title):
            // mt: the book chip, web's shape with `book`; Copy takes "§6.2 · p. 214".
            let plain = label.replacingOccurrences(of: "\u{00A0}", with: " ")
            return InlineViewAttachment(
                NotesChip(text: label, kind: .material, size: size, help: title) { actions?.open(target) }, plainText: plain, baseline: -scaled(3.5)
            )
        }
    }

    /// The chip a citation stands for; nil when it names no lecture of the course.
    func target(_ citation: ChatCitation) -> NotesChipTarget? {
        input.chips.target(citation)
    }

    /// The part's blocks as units (the section's own `## ` title left out: the heading unit has it).
    private func partUnits(_ part: LectureNotesPart, sectionKey: String, sparkle: Bool) -> [NotesUnit] {
        var units: [NotesUnit] = []
        var titleSkipped = sectionKey == LectureNotesFormat.overviewKey
        var sparklePending = sparkle
        var checkIndex = 0
        for (blockIndex, block) in part.blocks.enumerated() {
            switch block {
            case .markdown(let text):
                for (index, markdown) in parsed.blocks(text).enumerated() {
                    if case .heading(level: 2, text: _) = markdown, !titleSkipped {
                        titleSkipped = true
                        continue
                    }
                    units += markdownUnits(markdown, sectionKey: sectionKey, id: "\(blockIndex).\(index)", sparkle: &sparklePending)
                }
            case .fence(let fence):
                titleSkipped = true
                if fence.kind == .check {
                    units += checkUnits(fence, sectionKey: sectionKey, index: checkIndex)
                    checkIndex += 1
                } else {
                    units += fenceUnits(fence, sectionKey: sectionKey, id: "\(blockIndex)")
                }
            }
        }
        return units
    }

    private func markdownUnits(_ block: MarkdownBlock, sectionKey: String, id: String, sparkle: inout Bool) -> [NotesUnit] {
        switch block {
        case .paragraph(let text):
            let attributes = base(sectionKey, role: .body)
            let content = NSMutableAttributedString()
            if sparkle, let mark = ImageAttachment.symbol("sparkle", size: metrics.body - scaled(1), color: NotesNSInk.ai(dark)) {
                content.append(ImageAttachment.string(mark, baseline: -scaled(2), plainText: "", attributes: attributes))
                content.append(NSAttributedString(string: " ", attributes: attributes))
                sparkle = false
            }
            content.append(inline(text, attributes: attributes))
            return [unit("p|\(id)|\(text)|\(content.length)", content, section: sectionKey, role: .body)]
        case .heading(_, let text):
            let font = NSFont.systemFont(ofSize: metrics.subheading, weight: .semibold)
            let style = paragraphStyle(
                spacingBefore: max(scaled(4), scaled(18) - metrics.paragraphSpacing), spacing: scaled(6), font: font, lineHeight: font.pointSize + scaled(5)
            )
            let attributes = base(sectionKey, role: .body, font: font, color: labelInk, style: style)
            return [unit("h5|\(text)", inline(text, attributes: attributes, emphasisColor: labelInk), section: sectionKey, role: .body)]
        case .list(let items):
            return items.enumerated().map { index, item in
                let indent = scaled(22 + CGFloat(item.depth) * 18)
                let style = paragraphStyle(spacing: index == items.count - 1 ? metrics.paragraphSpacing : scaled(4), font: bodyFont)
                style.headIndent = indent
                style.firstLineHeadIndent = 0
                style.tabStops = [
                    NSTextTab(textAlignment: .right, location: indent - scaled(7), options: [:]), NSTextTab(textAlignment: .left, location: indent, options: [:])
                ]
                let attributes = base(sectionKey, role: .body, style: style)
                let text = NSMutableAttributedString(string: "\t", attributes: attributes)
                var marker = attributes
                marker[.foregroundColor] = item.isNumbered ? greyInk : NotesNSInk.tertiary(dark)
                if item.isNumbered { marker[.font] = NSFont.monospacedDigitSystemFont(ofSize: metrics.body, weight: .regular) }
                text.append(NSAttributedString(string: item.marker, attributes: marker))
                text.append(NSAttributedString(string: "\t", attributes: attributes))
                text.append(inline(item.text, attributes: attributes))
                return unit("li|\(id).\(index)|\(item.marker)|\(item.depth)|\(item.text)", text, section: sectionKey, role: .body)
            }
        case .table(let table):
            // A breakout: the page's full width.
            let attachment = HostedBlockAttachment(
                TableBlockView(table: table, size: metrics.small, zoom: metrics.zoom, fills: input.style == .page),
                estimate: CGFloat(table.rows.count + 1) * scaled(31), margin: 2,
                plainText: ([table.header] + table.rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
            )
            return [blockUnit(attachment, signature: "tb|\(id)|\(table.header)|\(table.rows)", sectionKey: sectionKey, spacing: scaled(14), breakout: true)]
        case .code(let code, let language):
            return [codeUnit(code, language: language, sectionKey: sectionKey, id: id)]
        case .quote(let text):
            return [calloutUnit(kind: "quote", text: text, sectionKey: sectionKey, id: id)]
        case .callout(let kind, let text):
            return [calloutUnit(kind: kind.rawValue, text: text, sectionKey: sectionKey, id: id)]
        case .rule:
            let attachment = HostedBlockAttachment(Hairline(), estimate: 1, margin: 6, measure: measure)
            return [blockUnit(attachment, signature: "hr|\(id)", sectionKey: sectionKey, spacing: scaled(8))]
        }
    }

    /// A callout on the quiet fill with one secondary glyph (`.call`), or a quote with a quiet bar:
    /// text, so it reads and selects with the rest; the fragment draws the fill.
    private func calloutUnit(kind: String, text: String, sectionKey: String, id: String) -> NotesUnit {
        let isQuote = kind == "quote"
        let style = paragraphStyle(spacingBefore: scaled(isQuote ? 2 : 12), spacing: isQuote ? metrics.paragraphSpacing : scaled(26), font: bodyFont)
        let indent = scaled(isQuote ? 12 : 40)
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.tailIndent = isQuote ? 0 : -scaled(14)
        var attributes = base(sectionKey, role: .body, style: style)
        attributes[.notesCallout] = kind
        let joined = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return unit("c|\(id)|\(kind)|\(joined)", inline(joined, attributes: attributes), section: sectionKey, role: .body)
    }

    /// Inline Markdown in Claude's grey: bold semibold primary, italic, code in SF Mono primary on
    /// the quiet fill, formulas as images, at most one chip per paragraph (density rule 4).
    func inline(_ text: String, attributes: [NSAttributedString.Key: Any], emphasisColor: NSColor? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = attributes[.font] as? NSFont ?? bodyFont
        var chips = 0
        for run in InlineMarkdown.runs(text) {
            switch run {
            case .text(let words, let style):
                var runAttributes = attributes
                if style.contains(.code) {
                    runAttributes[.font] = NSFont.monospacedSystemFont(ofSize: (font.pointSize * 0.88).rounded(), weight: .regular)
                    runAttributes[.foregroundColor] = labelInk
                    runAttributes[.backgroundColor] = NotesNSInk.quietFill(dark)
                } else {
                    var traits = font
                    if style.contains(.bold) {
                        traits = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
                        runAttributes[.foregroundColor] = emphasisColor ?? labelInk
                    }
                    if style.contains(.italic) { traits = NSFontManager.shared.convert(traits, toHaveTrait: .italicFontMask) }
                    runAttributes[.font] = traits
                }
                if style.contains(.strikethrough) { runAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                result.append(NSAttributedString(string: words, attributes: runAttributes))
            case .citation(let citation):
                guard chips == 0, let target = target(citation) else { continue }
                chips += 1
                var chipAttributes = attributes
                chipAttributes[.attachment] = chipAttachment(target).attachment()
                // The chip sits apart from the word before it.
                if let last = result.string.last, !last.isWhitespace { result.append(NSAttributedString(string: " ", attributes: attributes)) }
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: chipAttributes))
            case .math(let latex):
                if let image = MathRendering.image(latex, size: font.pointSize + 0.5, display: false, color: labelInk) {
                    let baseline = -((image.size.height - font.capHeight) / 2).rounded()
                    result.append(ImageAttachment.string(image, baseline: baseline, plainText: InlineMath.unicode(latex) ?? latex, attributes: attributes))
                } else {
                    var mathAttributes = attributes
                    mathAttributes[.foregroundColor] = labelInk
                    result.append(NSAttributedString(string: InlineMath.unicode(latex) ?? latex, attributes: mathAttributes))
                }
            }
        }
        // A trailing space before a chip-less end is dropped.
        while let last = result.string.last, last == " " { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    /// A block attachment on a line of its own: at the measure (indented with the prose; its
    /// attachment built with `measure`), or a breakout at the text view's full width.
    private func blockUnit(
        _ attachment: NotesAttachment, signature: String, sectionKey: String, role: NotesRole = .body, spacingBefore: CGFloat? = nil,
        spacing: CGFloat? = nil, breakout: Bool = false
    ) -> NotesUnit {
        attachment.host = actions
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore ?? scaled(2)
        style.paragraphSpacing = spacing ?? scaled(14)
        var attributes = base(sectionKey, role: role, style: style, atMeasure: !breakout)
        attributes[.attachment] = attachment.attachment()
        return unit(signature, NSAttributedString(string: "\u{FFFC}", attributes: attributes), section: sectionKey, role: role)
    }

    /// Code: a breakout at the page's full width.
    private func codeUnit(_ code: String, language: String, sectionKey: String, id: String) -> NotesUnit {
        let lines = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
        let attachment = HostedBlockAttachment(
            CodeBlockView(code: code, language: language, size: metrics.code, zoom: metrics.zoom),
            estimate: CGFloat(lines) * metrics.code * 1.5 + scaled(24), plainText: code
        )
        return blockUnit(attachment, signature: "code|\(id)|\(language)|\(code)", sectionKey: sectionKey, spacing: scaled(16), breakout: true)
    }

    // MARK: Fences

    private func fenceUnits(_ fence: NotesFence, sectionKey: String, id: String) -> [NotesUnit] {
        let signature = "f|\(id)|\(fence.info)|\(fence.isClosed)|\(fence.body)"
        if fence.kind == .code {
            return [codeUnit(fence.body, language: fence.language, sectionKey: sectionKey, id: id)]
        }
        // nl: an older version's `note` fence (the student's notes are beside the text now).
        if fence.kind == .note { return [] }
        guard fence.isClosed else {
            // A placeholder at about the block's final height until its fence closes: figures break
            // out, the rest sits at the measure.
            let height: CGFloat = switch fence.kind {
            case .chart: metrics.chartHeight + scaled(20)
            case .diagram: scaled(160)
            case .slide: metrics.slideWidth * 9 / 16 + scaled(26)
            case .math: scaled(30)
            default: scaled(40)
            }
            let breakout = fence.kind == .chart || fence.kind == .diagram || fence.kind == .slide
            let attachment = HostedBlockAttachment(PlaceholderBlock(height: height), estimate: height, margin: 2, measure: breakout ? nil : measure)
            return [blockUnit(attachment, signature: "ph|\(id)|\(fence.kind)", sectionKey: sectionKey, breakout: breakout)]
        }
        switch fence.kind {
        case .math:
            let latex = fence.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return [] }
            let style = paragraphStyle(spacingBefore: scaled(4), spacing: scaled(16), font: bodyFont)
            style.alignment = .center
            let attributes = base(sectionKey, role: .body, color: labelInk, style: style)
            if let image = MathRendering.image(latex, size: metrics.displayMath, display: true, color: labelInk) {
                return [unit(signature, ImageAttachment.string(image, baseline: -scaled(6), plainText: latex, attributes: attributes), section: sectionKey, role: .body)]
            }
            return [unit(signature, NSAttributedString(string: InlineMath.unicode(latex) ?? latex, attributes: attributes), section: sectionKey, role: .body)]
        case .diagram:
            // A breakout: spread to the page's width up to a cap, else centred (the page; in Review's
            // pane as before, at its natural size from the leading edge).
            guard case .success(let diagram) = Diagram.parse(fence.body) else { return [] }
            let layout = DiagramLayout.layout(diagram)
            let attachment = HostedBlockAttachment(
                DiagramView(diagram: diagram, scale: metrics.zoom, spreads: input.style == .page),
                estimate: layout.size.height * metrics.zoom, plainText: fence.body
            )
            return [blockUnit(attachment, signature: signature, sectionKey: sectionKey, spacingBefore: scaled(6), spacing: scaled(14), breakout: true)]
        case .chart:
            // A breakout at the page's width; it keeps its height.
            guard case .success(let spec) = ChartSpec.parse(fence.body) else { return [] }
            let attachment = HostedBlockAttachment(
                ChartBlockView(spec: spec, height: metrics.chartHeight, zoom: metrics.zoom), estimate: metrics.chartHeight + scaled(44),
                plainText: spec.title ?? ""
            )
            return [blockUnit(attachment, signature: signature, sectionKey: sectionKey, spacingBefore: scaled(6), spacing: scaled(14), breakout: true)]
        case .slide:
            // A breakout at most 640 wide (Review's pane: 296), centred on the page, its chip under its
            // leading edge; never the student's ink (nl: it is in Your notes and on Review's slide).
            guard let ref = NotesSlideRef.parse(fence.body), case .slide(let key, let page) = ref.citation,
                  input.lectures[key]?.id == input.lectureID, let deck = input.deck,
                  input.pages.map({ $0.contains(page) }) ?? true
            else { return [] }
            let width = metrics.slideWidth
            let actions = actions
            let lecture = input.lectureID
            let attachment = HostedBlockAttachment(
                SlideFigureView(
                    deck: deck, page: page, maxWidth: width, centred: input.style == .page, box: ref.box, caption: ref.caption,
                    zoom: metrics.zoom, services: actions?.services, openSlide: { actions?.open(.slide(lecture: lecture, page: page)) }
                ),
                estimate: width * 9 / 16 + scaled(26), plainText: "S\(page)"
            )
            return [blockUnit(attachment, signature: signature, sectionKey: sectionKey, spacingBefore: scaled(6), spacing: scaled(18), breakout: true)]
        case .quote:
            guard let citation = NotesQuoteRef.parse(fence.body), let row = NotesQuoteRef.row(citation, in: input.quotes) else { return [] }
            let actions = actions
            let lecture = input.lectureID
            let attachment = HostedBlockAttachment(
                ProfessorQuoteView(annotation: row, size: metrics.small, zoom: metrics.zoom) { time in
                    actions?.open(.moment(lecture: lecture, recording: row.recordingID, seconds: time))
                },
                estimate: scaled(40), margin: 2, plainText: "“\(row.body)”", measure: measure
            )
            return [blockUnit(attachment, signature: signature + "|\(row.id)|\(row.body)", sectionKey: sectionKey, spacingBefore: scaled(4), spacing: scaled(16))]
        case .note, .check, .code:
            return []
        }
    }

    /// Check yourself: the sub-heading, the numbered questions, one folded "Answers" disclosure;
    /// open, the answers numbered under it.
    private func checkUnits(_ fence: NotesFence, sectionKey: String, index: Int) -> [NotesUnit] {
        guard fence.isClosed else {
            let attachment = HostedBlockAttachment(PlaceholderBlock(height: scaled(60)), estimate: scaled(60), margin: 2, measure: measure)
            return [blockUnit(attachment, signature: "ph|check|\(index)", sectionKey: sectionKey)]
        }
        let items = NotesCheckItem.parse(fence.body)
        guard !items.isEmpty else { return [] }
        var units = markdownUnitsHeading("Check yourself", sectionKey: sectionKey)
        for (number, item) in items.enumerated() {
            units += numbered(number + 1, item.question, sectionKey: sectionKey, id: "q\(index).\(number)", last: false)
        }
        let key = "\(sectionKey)#\(index)"
        let isOpen = input.answersOpen.contains(key)
        let actions = actions
        let disclosure = HostedBlockAttachment(
            AnswersDisclosure(isOpen: isOpen, zoom: metrics.zoom) { actions?.toggleAnswers(key) }, estimate: scaled(20), margin: 0, measure: measure
        )
        units.append(blockUnit(
            disclosure, signature: "ans|\(key)|\(isOpen)", sectionKey: sectionKey, spacingBefore: 0, spacing: isOpen ? scaled(4) : metrics.paragraphSpacing
        ))
        if isOpen {
            for (number, item) in items.enumerated() {
                units += numbered(number + 1, item.answer, sectionKey: sectionKey, id: "a\(index).\(number)", last: number == items.count - 1)
            }
        }
        return units
    }

    private func markdownUnitsHeading(_ title: String, sectionKey: String) -> [NotesUnit] {
        var sparkle = false
        return markdownUnits(.heading(level: 3, text: title), sectionKey: sectionKey, id: "check", sparkle: &sparkle)
    }

    private func numbered(_ number: Int, _ text: String, sectionKey: String, id: String, last: Bool) -> [NotesUnit] {
        var sparkle = false
        return markdownUnits(.list([MarkdownBlock.ListItem(marker: "\(number).", depth: 0, text: text)]), sectionKey: sectionKey, id: id, sparkle: &sparkle)
    }

    // MARK: Kept answers and the writing state

    private func keptUnit(_ mark: LectureNotesMark, sectionKey: String, orphaned: Bool) -> NotesUnit {
        let actions = actions
        let attachment = HostedBlockAttachment(
            KeptAnswerView(
                mark: mark, orphaned: orphaned, size: metrics.small, zoom: metrics.zoom, chips: input.chips,
                open: { actions?.open($0) },
                hovered: { actions?.keptAnswerHovered(mark.id, $0) },
                remove: { actions?.removeKept(mark) },
                continueInChat: { actions?.continueInChat(mark) }
            ),
            estimate: scaled(90), margin: 0,
            plainText: "\(mark.question ?? "")\n\(LectureNotesText.readable(mark.answer ?? ""))", measure: measure
        )
        return blockUnit(
            attachment, signature: "k|\(mark.id)|\(mark.updatedAt.timeIntervalSinceReferenceDate)|\(orphaned)", sectionKey: sectionKey,
            role: .kept, spacingBefore: 0, spacing: scaled(16)
        )
    }

    private func skeletonUnit(_ sectionKey: String, widths: [CGFloat]) -> NotesUnit {
        let height = CGFloat(widths.count) * metrics.lineHeight
        let attachment = HostedBlockAttachment(
            SkeletonLines(widths: widths, lineHeight: metrics.lineHeight), estimate: height, margin: 5, measure: measure
        )
        return blockUnit(attachment, signature: "sk|\(sectionKey)|\(widths)", sectionKey: sectionKey, role: .chrome, spacingBefore: 0, spacing: scaled(6))
    }

    private func progressUnit(_ notes: LectureNotes, sectionKey: String) -> NotesUnit {
        let kind: NotesProgressLine.Kind
        if notes.state == .paused, let until = notes.pausedUntil {
            kind = .paused(until)
        } else {
            let words = Double(notes.body.split(whereSeparator: \.isWhitespace).count)
            let target = Double(max(1, notes.targetWords ?? 2_000))
            kind = .writing(min(0.98, max(0.02, words / target)))
        }
        let attachment = HostedBlockAttachment(NotesProgressLine(kind: kind, zoom: metrics.zoom), estimate: scaled(26), margin: 0, measure: measure)
        let signature: String = switch kind {
        case .writing(let fraction): "pr|w|\(Int(fraction * 100))"
        case .paused(let until): "pr|p|\(until.timeIntervalSinceReferenceDate)"
        }
        return blockUnit(attachment, signature: signature, sectionKey: sectionKey, role: .chrome, spacingBefore: scaled(2), spacing: scaled(4))
    }

    private func failureUnit(_ notes: LectureNotes, sectionKey: String) -> NotesUnit {
        let actions = actions
        let canWrite = input.canWriteAgain
        let attachment = HostedBlockAttachment(
            NotesFailureLine(reason: notes.error, canWrite: canWrite, zoom: metrics.zoom) { actions?.writeAgain() }, estimate: scaled(26), margin: 2,
            measure: measure
        )
        return blockUnit(attachment, signature: "fail|\(canWrite)|\(notes.error ?? "")", sectionKey: sectionKey, role: .chrome, spacingBefore: scaled(8))
    }

    private func lineUnit(_ sentence: String, sectionKey: String) -> NotesUnit {
        let font = NSFont.systemFont(ofSize: scaled(12))
        let attributes = base(
            sectionKey, role: .chrome, font: font, color: greyInk, style: paragraphStyle(spacingBefore: scaled(10), font: font, lineHeight: scaled(17))
        )
        return unit("line|\(sentence)", NSAttributedString(string: sentence, attributes: attributes), section: sectionKey, role: .chrome)
    }
}

/// Where marks were found in a section's text, by mark and text: a build re-anchors only the
/// sections whose text changed (a streaming version changes one at a time; folding, opening answers
/// or adding a mark change none). Cleared when it grows past 512 entries.
@MainActor
final class NotesAnchorCache {
    private struct Key: Hashable {
        var mark: LectureNotesMark.ID
        var text: Int
        var length: Int
        var fuzzy: Bool
    }

    private var located: [Key: NSRange?] = [:]

    func locate(_ mark: LectureNotesMark, in text: String, fuzzy: Bool) -> NSRange? {
        let key = Key(mark: mark.id, text: text.hashValue, length: text.utf16.count, fuzzy: fuzzy)
        if let found = located[key] { return found }
        if located.count >= 512 { located.removeAll(keepingCapacity: true) }
        let range = TextQuoteAnchor.locate(
            exact: mark.exact, prefix: mark.prefix, suffix: mark.suffix, hint: mark.startOffset, fuzzy: fuzzy, in: text
        )
        located[key] = .some(range)
        return range
    }
}

/// The notes' body and Markdown blocks as parsed (nl, §11): a zoom or appearance change builds the
/// document's attributes again without parsing anything again. Holds the last body's parse and
/// the blocks of up to 2,048 Markdown runs.
@MainActor
final class NotesParseCache {
    private var lastBody: String?
    private var lastDocument: LectureNotesDocument?
    private var markdown: [String: [MarkdownBlock]] = [:]

    func document(_ body: String) -> LectureNotesDocument {
        if body == lastBody, let lastDocument { return lastDocument }
        let document = LectureNotesFormat.parse(body)
        lastBody = body
        lastDocument = document
        return document
    }

    func blocks(_ text: String) -> [MarkdownBlock] {
        if let blocks = markdown[text] { return blocks }
        if markdown.count >= 2_048 { markdown.removeAll(keepingCapacity: true) }
        let blocks = MarkdownBlock.blocks(text, alerts: true)
        markdown[text] = blocks
        return blocks
    }
}

/// The one "Answers" disclosure under Check yourself (folded by default).
struct AnswersDisclosure: View {
    let isOpen: Bool
    var zoom: CGFloat = 1
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6 * zoom) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9 * zoom, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text("Answers")
                    .font(.system(size: 12 * zoom))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isOpen ? "Shown" : "Hidden"))
    }
}

/// Failed: what came stays; one secondary line, the triangle and the reason (in full on hover
/// when it is cut), then Write Again… (off while nothing could be written: no slides with pages,
/// no transcript).
struct NotesFailureLine: View {
    let reason: String?
    var canWrite = true
    var zoom: CGFloat = 1
    let writeAgain: () -> Void

    var body: some View {
        HStack(spacing: 6 * zoom) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if let reason, !reason.isEmpty {
                Text(verbatim: reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(verbatim: reason))
            }
            Button("Write Again…", action: writeAgain)
                .buttonStyle(.borderless)
                .disabled(!canWrite)
                .fixedSize()
                .padding(.leading, 2)
        }
        .font(.system(size: 12 * zoom))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
#endif
