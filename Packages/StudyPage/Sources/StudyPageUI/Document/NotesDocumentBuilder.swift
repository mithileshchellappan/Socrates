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
    func editInReview(_ note: Note)
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

/// The notes as one read-only TextKit document (docs/plan-lecture-notes.md §2): the overview with
/// the document's one sparkle, then one section per topic (heading with its chip and the amber
/// star, Claude's prose in grey with primary emphasis, figures, the professor's quotes, the
/// student's notes in primary, Check yourself), the student's highlights and kept answers.
@MainActor
final class NotesDocumentBuilder {
    let input: NotesDocumentInput
    let metrics: NotesMetrics
    let containerWidth: CGFloat
    weak var actions: (any NotesDocumentActions)?
    let noteRendering: NoteTextRendering
    /// Changes everything (style, appearance): part of every signature.
    let stamp: String

    private var dark: Bool { input.isDark }
    private var labelInk: NSColor { NotesNSInk.label(dark) }
    private var greyInk: NSColor { NotesNSInk.secondary(dark) }

    init(input: NotesDocumentInput, containerWidth: CGFloat, actions: any NotesDocumentActions, noteRendering: NoteTextRendering) {
        self.input = input
        metrics = NotesMetrics(style: input.style)
        self.containerWidth = containerWidth
        self.actions = actions
        self.noteRendering = noteRendering
        stamp = "\(input.style)|\(input.isDark)"
    }

    // MARK: The document

    func build() -> NotesBuild {
        var build = NotesBuild()
        guard let notes = input.notes, notes.hasText else {
            build.units = placeholderDocument()
            return build
        }
        let document = LectureNotesFormat.parse(notes.body)
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
                let range = body.isEmpty ? nil : TextQuoteAnchor.locate(
                    exact: mark.exact, prefix: mark.prefix, suffix: mark.suffix, hint: mark.startOffset, in: text
                )
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

    /// Before the text: the outline's headings over skeleton lines (queued, or no Claude Code with
    /// the student's notes in place and one line saying why).
    private func placeholderDocument() -> [NotesUnit] {
        var units: [NotesUnit] = []
        let outline = input.outline
        if let sentence = input.unavailable {
            var remaining = input.studentNotes.filter { !$0.isBlank }
            for section in outline {
                units.append(headingUnit(section, title: section.title))
                let inSection = remaining.filter { note in
                    if let page = note.pageNumber { return section.covers(page: page) }
                    if let time = note.audioTime, let start = section.startTime { return time >= start && time < (section.endTime ?? .infinity) }
                    return false
                }
                remaining.removeAll { note in inSection.contains { $0.id == note.id } }
                for note in inSection { units.append(studentNoteUnit(note, sectionKey: section.key)) }
            }
            for note in remaining { units.append(studentNoteUnit(note, sectionKey: outline.last?.key ?? LectureNotesFormat.overviewKey)) }
            units.append(lineUnit(sentence, sectionKey: outline.last?.key ?? LectureNotesFormat.overviewKey))
            return units
        }
        if let notes = input.notes, notes.state == .paused {
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

    private func base(_ sectionKey: String, role: NotesRole, font: NSFont? = nil, color: NSColor? = nil, style: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        let font = font ?? bodyFont
        return [
            .font: font,
            .foregroundColor: color ?? greyInk,
            .paragraphStyle: style ?? paragraphStyle(font: font),
            .notesSection: sectionKey,
            .notesRole: role.rawValue
        ]
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
        let style = paragraphStyle(spacingBefore: metrics.sectionSpacingBefore - metrics.paragraphSpacing, spacing: 8, font: font, lineHeight: font.pointSize + 5)
        style.tabStops = [NSTextTab(textAlignment: .right, location: max(40, containerWidth), options: [:])]
        style.tailIndent = 0
        var attributes = base(section.key, role: .heading, font: font, color: labelInk, style: style)
        attributes[.notesHeading] = section.key
        let text = NSMutableAttributedString(string: title, attributes: attributes)
        if section.hasExamHint, let star = ImageAttachment.symbol("star", size: metrics.sectionHeading - 3, weight: .semibold, color: NotesNSInk.professor(dark)) {
            text.append(NSAttributedString(string: " ", attributes: attributes))
            text.append(ImageAttachment.string(star, baseline: -1, plainText: "", attributes: attributes))
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
        return unit("h|\(section.key)|\(title)|\(section.hasExamHint)|\(chipSignature)|\(folded)|\(Int(containerWidth))", text, section: section.key, role: .heading)
    }

    private func headingChip(_ section: LectureNotesSection) -> (attachment: NotesAttachment, signature: String)? {
        let lecture = input.lectureID
        if input.hasRecording, let start = section.startTime {
            let target = NotesChipTarget.moment(lecture: lecture, recording: nil, seconds: start)
            return (chipAttachment(target), "t\(Int(start))")
        }
        if let page = section.firstPage {
            return (chipAttachment(.slide(lecture: lecture, page: page)), "s\(page)")
        }
        return nil
    }

    /// A chip: `TimeChip` (a moment) or `SlideChip`, "L2 · S14" for another lecture's.
    private func chipAttachment(_ target: NotesChipTarget) -> NotesAttachment {
        let actions = actions
        switch target {
        case .slide(let lecture, let page):
            let prefix = lecture == input.lectureID ? nil : input.lectures.values.first { $0.id == lecture }?.number.map { "L\($0)" }
            let text = prefix.map { "\($0) · S\(page)" } ?? "S\(page)"
            if prefix == nil {
                return InlineViewAttachment(SlideChip(page: page) { actions?.open(target) }, plainText: text)
            }
            return InlineViewAttachment(PrefixedSlideChip(text: text) { actions?.open(target) }, plainText: text)
        case .moment(_, _, let seconds):
            let prefix = target.lectureID == input.lectureID ? nil : input.lectures.values.first { $0.id == target.lectureID }?.number.map { "L\($0)" }
            return InlineViewAttachment(
                TimeChip(seconds, prefix: prefix, showsPlayGlyph: true) { actions?.open(target) },
                plainText: prefix.map { "\($0) · \(TimeText.clock(seconds))" } ?? TimeText.clock(seconds)
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
                for (index, markdown) in MarkdownBlock.blocks(text, alerts: true).enumerated() {
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
            if sparkle, let mark = ImageAttachment.symbol("sparkle", size: metrics.body - 1, color: NotesNSInk.ai(dark)) {
                content.append(ImageAttachment.string(mark, baseline: -2, plainText: "", attributes: attributes))
                content.append(NSAttributedString(string: " ", attributes: attributes))
                sparkle = false
            }
            content.append(inline(text, attributes: attributes))
            return [unit("p|\(id)|\(text)|\(content.length)", content, section: sectionKey, role: .body)]
        case .heading(_, let text):
            let font = NSFont.systemFont(ofSize: metrics.subheading, weight: .semibold)
            let style = paragraphStyle(spacingBefore: max(4, 18 - metrics.paragraphSpacing), spacing: 6, font: font, lineHeight: font.pointSize + 5)
            let attributes = base(sectionKey, role: .body, font: font, color: labelInk, style: style)
            return [unit("h5|\(text)", inline(text, attributes: attributes, emphasisColor: labelInk), section: sectionKey, role: .body)]
        case .list(let items):
            return items.enumerated().map { index, item in
                let indent: CGFloat = 22 + CGFloat(item.depth) * 18
                let style = paragraphStyle(spacing: index == items.count - 1 ? metrics.paragraphSpacing : 4, font: bodyFont)
                style.headIndent = indent
                style.firstLineHeadIndent = 0
                style.tabStops = [
                    NSTextTab(textAlignment: .right, location: indent - 7, options: [:]), NSTextTab(textAlignment: .left, location: indent, options: [:])
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
            let attachment = HostedBlockAttachment(
                TableBlockView(table: table, size: metrics.small), estimate: CGFloat(table.rows.count + 1) * 31, margin: 2,
                plainText: ([table.header] + table.rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
            )
            return [blockUnit(attachment, signature: "tb|\(id)|\(table.header)|\(table.rows)", sectionKey: sectionKey, spacing: 14)]
        case .code(let code, let language):
            return [codeUnit(code, language: language, sectionKey: sectionKey, id: id)]
        case .quote(let text):
            return [calloutUnit(kind: "quote", text: text, sectionKey: sectionKey, id: id)]
        case .callout(let kind, let text):
            return [calloutUnit(kind: kind.rawValue, text: text, sectionKey: sectionKey, id: id)]
        case .rule:
            let attachment = HostedBlockAttachment(Hairline(), estimate: 1, margin: 6)
            return [blockUnit(attachment, signature: "hr|\(id)", sectionKey: sectionKey, spacing: 8)]
        }
    }

    /// A callout on the quiet fill with one secondary glyph (`.call`), or a quote with a quiet bar:
    /// text, so it reads and selects with the rest; the fragment draws the fill.
    private func calloutUnit(kind: String, text: String, sectionKey: String, id: String) -> NotesUnit {
        let isQuote = kind == "quote"
        let style = paragraphStyle(spacingBefore: isQuote ? 2 : 12, spacing: isQuote ? metrics.paragraphSpacing : 26, font: bodyFont)
        let indent: CGFloat = isQuote ? 12 : 40
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.tailIndent = isQuote ? 0 : -14
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

    /// A block attachment on a line of its own.
    private func blockUnit(_ attachment: NotesAttachment, signature: String, sectionKey: String, role: NotesRole = .body, spacingBefore: CGFloat = 2, spacing: CGFloat = 14) -> NotesUnit {
        attachment.host = actions
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing
        var attributes = base(sectionKey, role: role, style: style)
        attributes[.attachment] = attachment.attachment()
        return unit(signature, NSAttributedString(string: "\u{FFFC}", attributes: attributes), section: sectionKey, role: role)
    }

    private func codeUnit(_ code: String, language: String, sectionKey: String, id: String) -> NotesUnit {
        let lines = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
        let attachment = HostedBlockAttachment(
            CodeBlockView(code: code, language: language, size: metrics.code), estimate: CGFloat(lines) * metrics.code * 1.5 + 24,
            plainText: code
        )
        return blockUnit(attachment, signature: "code|\(id)|\(language)|\(code)", sectionKey: sectionKey, spacing: 16)
    }

    // MARK: Fences

    private func fenceUnits(_ fence: NotesFence, sectionKey: String, id: String) -> [NotesUnit] {
        let signature = "f|\(id)|\(fence.info)|\(fence.isClosed)|\(fence.body)"
        if fence.kind == .code {
            return [codeUnit(fence.body, language: fence.language, sectionKey: sectionKey, id: id)]
        }
        guard fence.isClosed else {
            // A placeholder at about the block's final height until its fence closes.
            let height: CGFloat = switch fence.kind {
            case .chart: metrics.chartHeight + 20
            case .diagram: 160
            case .slide: metrics.slideWidth * 9 / 16 + 26
            case .math: 30
            default: 40
            }
            return [blockUnit(HostedBlockAttachment(PlaceholderBlock(height: height), estimate: height, margin: 2), signature: "ph|\(id)|\(fence.kind)", sectionKey: sectionKey)]
        }
        switch fence.kind {
        case .math:
            let latex = fence.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return [] }
            let size = metrics.style == .page ? 17.0 : 15.0
            let style = paragraphStyle(spacingBefore: 4, spacing: 16, font: bodyFont)
            style.alignment = .center
            let attributes = base(sectionKey, role: .body, color: labelInk, style: style)
            if let image = MathRendering.image(latex, size: size, display: true, color: labelInk) {
                return [unit(signature, ImageAttachment.string(image, baseline: -6, plainText: latex, attributes: attributes), section: sectionKey, role: .body)]
            }
            return [unit(signature, NSAttributedString(string: InlineMath.unicode(latex) ?? latex, attributes: attributes), section: sectionKey, role: .body)]
        case .diagram:
            guard case .success(let diagram) = Diagram.parse(fence.body) else { return [] }
            let layout = DiagramLayout.layout(diagram)
            let attachment = HostedBlockAttachment(DiagramView(diagram: diagram), estimate: layout.size.height, plainText: fence.body)
            return [blockUnit(attachment, signature: signature, sectionKey: sectionKey, spacingBefore: 6, spacing: 14)]
        case .chart:
            guard case .success(let spec) = ChartSpec.parse(fence.body) else { return [] }
            let attachment = HostedBlockAttachment(
                ChartBlockView(spec: spec, height: metrics.chartHeight), estimate: metrics.chartHeight + 44, plainText: spec.title ?? ""
            )
            return [blockUnit(attachment, signature: signature, sectionKey: sectionKey, spacingBefore: 6, spacing: 14)]
        case .slide:
            guard let ref = NotesSlideRef.parse(fence.body), case .slide(let key, let page) = ref.citation,
                  input.lectures[key]?.id == input.lectureID, let deck = input.deck,
                  input.pages.map({ $0.contains(page) }) ?? true
            else { return [] }
            let width = min(metrics.slideWidth, containerWidth)
            let actions = actions
            let lecture = input.lectureID
            let attachment = HostedBlockAttachment(
                SlideFigureView(
                    deck: deck, page: page, box: ref.box, caption: ref.caption, width: width, services: actions?.services,
                    openSlide: { actions?.open(.slide(lecture: lecture, page: page)) }
                ),
                estimate: width * 9 / 16 + 26, plainText: "S\(page)"
            )
            return [blockUnit(attachment, signature: signature + "|\(Int(width))", sectionKey: sectionKey, spacingBefore: 6, spacing: 18)]
        case .quote:
            guard let citation = NotesQuoteRef.parse(fence.body), case .moment(_, _, let seconds) = citation,
                  let row = input.quotes.first(where: { NotesQuoteRef.matches($0, seconds: seconds) })
            else { return [] }
            let actions = actions
            let lecture = input.lectureID
            let attachment = HostedBlockAttachment(
                ProfessorQuoteView(annotation: row, size: metrics.small) { time in
                    actions?.open(.moment(lecture: lecture, recording: row.recordingID, seconds: time))
                },
                estimate: 40, margin: 2, plainText: "“\(row.body)”"
            )
            return [blockUnit(attachment, signature: signature + "|\(row.id)|\(row.body)", sectionKey: sectionKey, spacingBefore: 4, spacing: 16)]
        case .note:
            guard let key = NotesNoteRef.parse(fence.body),
                  let note = input.studentNotes.first(where: { ChatCitation.key($0.id) == key }), !note.isBlank
            else { return [] }
            return [studentNoteUnit(note, sectionKey: sectionKey)]
        case .check, .code:
            return []
        }
    }

    /// The student's note, as Notes draws it (primary, no sparkle), with its `SlideChip`: live,
    /// so a note written later in Review shows here without a new version.
    func studentNoteUnit(_ note: Note, sectionKey: String) -> NotesUnit {
        let rendered = NSMutableAttributedString(attributedString: noteRendering.text(note.blocks))
        let whole = NSRange(location: 0, length: rendered.length)
        rendered.addAttributes([
            .notesSection: sectionKey, .notesRole: NotesRole.studentNote.rawValue, .notesStudentNote: note.id.uuidString
        ], range: whole)
        if let page = note.pageNumber {
            var attributes = rendered.length > 0 ? rendered.attributes(at: rendered.length - 1, effectiveRange: nil) : base(sectionKey, role: .studentNote)
            attributes[.attachment] = chipAttachment(.slide(lecture: input.lectureID, page: page)).attachment()
            attributes[.link] = nil
            rendered.append(NSAttributedString(string: " ", attributes: attributes.filter { $0.key != .attachment }))
            rendered.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }
        return unit("n|\(note.id)|\(note.updatedAt.timeIntervalSinceReferenceDate)", rendered, section: sectionKey, role: .studentNote)
    }

    /// Check yourself: the sub-heading, the numbered questions, one folded "Answers" disclosure;
    /// open, the answers numbered under it.
    private func checkUnits(_ fence: NotesFence, sectionKey: String, index: Int) -> [NotesUnit] {
        guard fence.isClosed else {
            return [blockUnit(HostedBlockAttachment(PlaceholderBlock(height: 60), estimate: 60, margin: 2), signature: "ph|check|\(index)", sectionKey: sectionKey)]
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
            AnswersDisclosure(isOpen: isOpen) { actions?.toggleAnswers(key) }, estimate: 20, margin: 0
        )
        units.append(blockUnit(disclosure, signature: "ans|\(key)|\(isOpen)", sectionKey: sectionKey, spacingBefore: 0, spacing: isOpen ? 4 : metrics.paragraphSpacing))
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
                mark: mark, orphaned: orphaned, size: metrics.small, chips: input.chips,
                open: { actions?.open($0) },
                hovered: { actions?.keptAnswerHovered(mark.id, $0) },
                remove: { actions?.removeKept(mark) },
                continueInChat: { actions?.continueInChat(mark) }
            ),
            estimate: 90, margin: 0,
            plainText: "\(mark.question ?? "")\n\(LectureNotesText.readable(mark.answer ?? ""))"
        )
        return blockUnit(
            attachment, signature: "k|\(mark.id)|\(mark.updatedAt.timeIntervalSinceReferenceDate)|\(orphaned)", sectionKey: sectionKey,
            role: .kept, spacingBefore: 0, spacing: 16
        )
    }

    private func skeletonUnit(_ sectionKey: String, widths: [CGFloat]) -> NotesUnit {
        let height = CGFloat(widths.count) * metrics.lineHeight
        let attachment = HostedBlockAttachment(SkeletonLines(widths: widths, lineHeight: metrics.lineHeight), estimate: height, margin: 5)
        return blockUnit(attachment, signature: "sk|\(sectionKey)|\(widths)", sectionKey: sectionKey, role: .chrome, spacingBefore: 0, spacing: 6)
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
        let attachment = HostedBlockAttachment(NotesProgressLine(kind: kind), estimate: 26, margin: 0)
        let signature: String = switch kind {
        case .writing(let fraction): "pr|w|\(Int(fraction * 100))"
        case .paused(let until): "pr|p|\(until.timeIntervalSinceReferenceDate)"
        }
        return blockUnit(attachment, signature: signature, sectionKey: sectionKey, role: .chrome, spacingBefore: 2, spacing: 4)
    }

    private func failureUnit(_ notes: LectureNotes, sectionKey: String) -> NotesUnit {
        let actions = actions
        let attachment = HostedBlockAttachment(
            NotesFailureLine(reason: notes.error) { actions?.writeAgain() }, estimate: 26, margin: 2
        )
        return blockUnit(attachment, signature: "fail|\(notes.error ?? "")", sectionKey: sectionKey, role: .chrome, spacingBefore: 8)
    }

    private func lineUnit(_ sentence: String, sectionKey: String) -> NotesUnit {
        let font = NSFont.systemFont(ofSize: 12)
        let attributes = base(sectionKey, role: .chrome, font: font, color: greyInk, style: paragraphStyle(spacingBefore: 10, font: font, lineHeight: 17))
        return unit("line|\(sentence)", NSAttributedString(string: sentence, attributes: attributes), section: sectionKey, role: .chrome)
    }
}

/// "S13", or "L2 · S14" for another lecture's slide: `SlideChip`'s capsule with a prefix.
struct PrefixedSlideChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: text)
                .monospacedDigit()
                .font(.chip)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(.secondary)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: text))
    }
}

/// The one "Answers" disclosure under Check yourself (folded by default).
struct AnswersDisclosure: View {
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text("Answers")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isOpen ? "Shown" : "Hidden"))
    }
}

/// Failed: what came stays; the secondary triangle with the reason on hover, then Write Again….
struct NotesFailureLine: View {
    let reason: String?
    let writeAgain: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .help(Text(verbatim: reason ?? ""))
                .accessibilityLabel(Text(verbatim: reason ?? ""))
            Button("Write Again…", action: writeAgain)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
