#if os(macOS)
import AppKit
import Notes
import StudyCore
import StudyUI
import SwiftUI
import UniformTypeIdentifiers

/// The note's text: `NSTextView` on TextKit 2 (docs/plan-m6.md §5.1). Lists continue on ↩ and
/// end on ↩ in an empty item; Tab and ⇧Tab indent; ⌫ at the start of an item ends the list there;
/// the boxes toggle on click; the Format keys apply without the menu (the menu shows them:
/// `NoteFormatCommands`). Paste and drop: images become inline images, note text keeps its
/// chips and media, other text pastes plain in the paragraph's format.
final class NoteTextView: NSTextView {
    weak var noteCoordinator: NoteEditorCoordinator?
    /// The document's stamp ("16 October 2026 at 09:41"), centred over the text.
    let stampLabel = NSTextField(labelWithString: "")
    var isDocument = false {
        didSet { updateInsets() }
    }

    /// A view after the last word (Review: the note's time chip), on the next line when it does
    /// not fit.
    var trailingAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let trailingAccessory { addSubview(trailingAccessory) }
            needsLayout = true
        }
    }

    static let blocksType = NSPasteboard.PasteboardType("com.example.studyportal.note-blocks")
    private static let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    private static let heicType = NSPasteboard.PasteboardType(UTType.heic.identifier)

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            updateInsets()
            noteCoordinator?.sizeChanged()
        }
    }

    override func layout() {
        super.layout()
        positionStamp()
        positionTrailingAccessory()
    }

    /// The document's text column: 52 pt in from the left (Apple Notes), at most 680 wide, under
    /// the stamp. A wide editor leaves the room on the right, never a gap before the text.
    func updateInsets() {
        guard isDocument else { return }
        let side = NoteMetrics.documentSide
        let inset = NSSize(width: side, height: 27)
        if textContainerInset != inset { textContainerInset = inset }
        let width = max(120, min(NoteMetrics.documentWidth, bounds.width - side * 2)).rounded()
        if let container = textContainer, container.size.width != width {
            container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        if stampLabel.superview == nil {
            stampLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            stampLabel.textColor = .tertiaryLabelColor
            stampLabel.alignment = .center
            addSubview(stampLabel)
        }
        positionStamp()
    }

    private func positionStamp() {
        guard isDocument else { return }
        stampLabel.sizeToFit()
        let size = stampLabel.frame.size
        // Centred over the text column.
        let column = textContainer?.size.width ?? bounds.width
        stampLabel.frame = CGRect(x: (textContainerOrigin.x + (column - size.width) / 2).rounded(), y: 2, width: size.width, height: size.height)
    }

    /// The end of the text in view coordinates: the last line's trailing edge and its line box.
    func endOfText() -> (x: CGFloat, top: CGFloat, height: CGFloat)? {
        guard let layout = textLayoutManager else { return nil }
        var last: NSTextLayoutFragment?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            last = fragment
            return false
        }
        guard let fragment = last, let line = fragment.textLineFragments.last else { return nil }
        let origin = textContainerOrigin
        let frame = fragment.layoutFragmentFrame
        let font = NSFont.systemFont(ofSize: noteCoordinator?.metrics.bodySize ?? 13)
        let height = ceil(font.ascender - font.descender + font.leading)
        return (origin.x + frame.minX + line.typographicBounds.maxX, origin.y + frame.minY + line.typographicBounds.minY, height)
    }

    /// Extra height the trailing accessory needs when it goes on a line of its own.
    private(set) var accessoryOverflow: CGFloat = 0

    /// Where the trailing accessory goes: after the last word when it fits, else at the start of
    /// the next line (`overflow`: the height that adds). Computes only; never moves a view.
    private func trailingAccessoryLayout() -> (frame: CGRect, overflow: CGFloat)? {
        guard let accessory = trailingAccessory else { return nil }
        let size = accessory.fittingSize
        let width = textContainer?.size.width ?? bounds.width
        guard let end = endOfText() else { return (CGRect(origin: .zero, size: size), 0) }
        let gap: CGFloat = 5
        if end.x - textContainerOrigin.x + gap + size.width <= width {
            return (CGRect(x: end.x + gap, y: (end.top + (end.height - size.height) / 2).rounded(), width: size.width, height: size.height), 0)
        }
        let top = end.top + end.height + 4
        return (CGRect(x: textContainerOrigin.x, y: top, width: size.width, height: size.height), size.height + 4)
    }

    func positionTrailingAccessory() {
        guard let accessory = trailingAccessory, let layout = trailingAccessoryLayout() else {
            accessoryOverflow = 0
            return
        }
        accessoryOverflow = layout.overflow
        if accessory.frame != layout.frame { accessory.frame = layout.frame }
    }

    /// The text's height (inspector style: the view is as tall as its text).
    func contentHeight() -> CGFloat {
        guard let layout = textLayoutManager else { return 0 }
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer.height
        let overflow = trailingAccessoryLayout()?.overflow ?? 0
        return ceil(used + textContainerInset.height * 2 + overflow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The list markers resolve their colours when drawn.
        needsDisplay = true
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { noteCoordinator?.focusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { noteCoordinator?.focusChanged(false) }
        return resigned
    }

    // MARK: Paragraphs

    /// The paragraph ranges the selection touches (an empty last paragraph is a zero-length range).
    func selectedParagraphs() -> [NSRange] {
        let string = self.string as NSString
        let selection = selectedRange()
        guard string.length > 0 else { return [NSRange(location: 0, length: 0)] }
        if selection.location >= string.length {
            let last = string.paragraphRange(for: NSRange(location: string.length - 1, length: 0))
            let lastChar = string.character(at: string.length - 1)
            // After a final newline the caret is on an empty paragraph of its own.
            if lastChar == 0x0A || lastChar == 0x0D || lastChar == 0x2029 {
                return [NSRange(location: string.length, length: 0)]
            }
            return [last]
        }
        var ranges: [NSRange] = []
        var location = selection.location
        let end = max(selection.location, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0))
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location <= end && location < string.length
        return ranges
    }

    /// The format of the paragraph at `range` (an empty last paragraph: the typing attributes').
    func format(of paragraph: NSRange) -> BlockFormat {
        if paragraph.length > 0, let storage = textStorage, paragraph.location < storage.length {
            return storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockFormat ?? .body
        }
        return typingAttributes[.noteBlock] as? BlockFormat ?? .body
    }

    /// The paragraph's text without its newline.
    func content(of paragraph: NSRange) -> NSRange {
        let string = self.string as NSString
        var content = paragraph
        while content.length > 0 {
            let character = string.character(at: NSMaxRange(content) - 1)
            guard character == 0x0A || character == 0x0D || character == 0x2029 else { break }
            content.length -= 1
        }
        return content
    }

    /// Sets the format of `paragraphs`, as one undo step.
    func setFormat(_ make: (BlockFormat) -> BlockFormat, paragraphs: [NSRange]) {
        guard let coordinator = noteCoordinator, let storage = textStorage else { return }
        let caretParagraph = selectedParagraphs().last
        var changed = false
        for paragraph in paragraphs {
            let current = format(of: paragraph)
            let next = make(current)
            if paragraph.length == 0 || paragraph == caretParagraph {
                typingAttributes = coordinator.typingAttributes(next, keeping: typingAttributes)
            }
            guard paragraph.length > 0, !next.isEqual(current) else { continue }
            if !changed {
                let union = paragraphs.filter { $0.length > 0 }.reduce(paragraph) { NSUnionRange($0, $1) }
                guard shouldChangeText(in: union, replacementString: nil) else { return }
                storage.beginEditing()
                changed = true
            }
            coordinator.apply(next, to: paragraph, in: storage)
        }
        if changed {
            storage.endEditing()
            didChangeText()
        }
    }

    func apply(_ kind: NoteParagraphKind) {
        let paragraphs = selectedParagraphs()
        let all = paragraphs.allSatisfy { format(of: $0).paragraphKind == kind }
        // A list format applied to a list of that kind turns it back into body text (Notes).
        let target: NoteParagraphKind = all && (kind == .checklist || kind == .bulleted || kind == .numbered) ? .body : kind
        setFormat({ BlockFormat.make(target, from: $0) }, paragraphs: paragraphs)
    }

    func indent(by delta: Int) -> Bool {
        let paragraphs = selectedParagraphs()
        guard paragraphs.allSatisfy({ format(of: $0).isList }) else { return false }
        setFormat({ $0.with(level: min(6, max(0, $0.level + delta))) }, paragraphs: paragraphs)
        return true
    }

    // MARK: Character styles

    func toggle(_ mark: NoteMark) {
        guard let coordinator = noteCoordinator, let storage = textStorage else { return }
        let key = NoteEditorCoordinator.key(for: mark)
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else {
            var attributes = typingAttributes
            let on = attributes[key] as? Bool == true
            attributes = coordinator.attributes(attributes, setting: mark, on: !on)
            typingAttributes = attributes
            return
        }
        var allOn = true
        for range in ranges {
            storage.enumerateAttribute(key, in: range) { value, _, stop in
                if value as? Bool != true {
                    allOn = false
                    stop.pointee = true
                }
            }
        }
        let union = ranges.dropFirst().reduce(ranges[0]) { NSUnionRange($0, $1) }
        guard shouldChangeText(in: union, replacementString: nil) else { return }
        storage.beginEditing()
        for range in ranges {
            storage.enumerateAttributes(in: range) { attributes, sub, _ in
                guard attributes[.attachment] == nil else { return }
                let next = coordinator.attributes(attributes, setting: mark, on: !allOn)
                storage.setAttributes(next, range: sub)
            }
        }
        storage.endEditing()
        didChangeText()
    }

    // MARK: Inserting

    /// Replaces the selection with `text` as one undo step and puts the caret after it. A
    /// composition in progress (a dead key, an input method) is committed first, and the range is
    /// clamped to the text (an image import finishing late may find it changed).
    func insert(_ text: NSAttributedString) {
        guard let storage = textStorage else { return }
        if hasMarkedText() { unmarkText() }
        let length = storage.length
        let selection = selectedRange()
        let location = min(selection.location, length)
        let range = NSRange(location: location, length: min(selection.length, length - location))
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// An attachment in the paragraph at the caret (a chip, an image, a sketch, a slide clip).
    func insertInline(_ attachment: any NoteAttachmentContent) {
        guard let coordinator = noteCoordinator else { return }
        let format = format(of: selectedParagraphs().last ?? NSRange(location: 0, length: 0))
        insert(coordinator.builder.attachment(attachment, format: format))
    }

    /// A block of its own (a professor quote): its own paragraph, the caret on a body line after it.
    func insertStandalone(_ attachment: any NoteAttachmentContent) {
        guard let coordinator = noteCoordinator else { return }
        let paragraph = selectedParagraphs().last ?? NSRange(location: 0, length: 0)
        let current = format(of: paragraph)
        let content = content(of: paragraph)
        let text = NSMutableAttributedString()
        let atEmptyLine = content.length == 0
        if !atEmptyLine {
            // End the current paragraph where the caret is.
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            text.append(NSAttributedString(string: "\n", attributes: coordinator.typesetter.paragraphAttributes(current)))
        }
        text.append(coordinator.builder.attachment(attachment, format: .body))
        text.append(NSAttributedString(string: "\n", attributes: coordinator.typesetter.paragraphAttributes(.body)))
        insert(text)
        typingAttributes = coordinator.typesetter.paragraphAttributes(.body)
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        guard let coordinator = noteCoordinator else { return super.insertNewline(sender) }
        let paragraph = selectedParagraphs().last ?? NSRange(location: 0, length: 0)
        let current = format(of: paragraph)
        let isEmpty = content(of: paragraph).length == 0
        if current.isList, isEmpty, selectedRange().length == 0 {
            // ↩ in an empty item ends the list.
            setFormat({ _ in BlockFormat(kind: .paragraph, origin: nil) }, paragraphs: [paragraph])
            return
        }
        super.insertNewline(sender)
        // The new paragraph: the next item of the list (unchecked), or body after a heading.
        let next: BlockFormat? = if current.isList {
            current.checked ? current.with(checked: false) : nil
        } else if current.kind == .heading {
            .body
        } else {
            nil
        }
        guard let next else { return }
        let newParagraph = selectedParagraphs().last ?? NSRange(location: selectedRange().location, length: 0)
        if current.kind == .heading, content(of: newParagraph).length > 0 {
            // A heading split in two stays a heading on both sides.
            return
        }
        typingAttributes = coordinator.typingAttributes(next, keeping: typingAttributes)
        if newParagraph.length > 0, let storage = textStorage {
            storage.beginEditing()
            coordinator.apply(next, to: newParagraph, in: storage)
            storage.endEditing()
        }
    }

    override func insertTab(_ sender: Any?) {
        if !indent(by: 1) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !indent(by: -1) { super.insertBacktab(sender) }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let paragraph = selectedParagraphs().last, selection.location == paragraph.location {
            let current = format(of: paragraph)
            if current.isList {
                // ⌫ at the start of an item: out one level, then out of the list.
                setFormat({ $0.level > 0 ? $0.with(level: $0.level - 1) : BlockFormat(kind: .paragraph) }, paragraphs: [paragraph])
                return
            }
            if current.kind == .heading, content(of: paragraph).length == 0 {
                setFormat({ _ in .body }, paragraphs: [paragraph])
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc ends drawing on a sketch; it never opens completion.
        noteCoordinator?.context.endEditingSketch()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEditable, window?.firstResponder === self,
              let character = event.characters(byApplyingModifiers: [])?.lowercased(), !character.isEmpty
        else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        func matches(_ shortcut: KeyboardShortcut) -> Bool {
            var wanted: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { wanted.insert(.command) }
            if shortcut.modifiers.contains(.shift) { wanted.insert(.shift) }
            if shortcut.modifiers.contains(.option) { wanted.insert(.option) }
            if shortcut.modifiers.contains(.control) { wanted.insert(.control) }
            return flags == wanted && String(shortcut.key.character).lowercased() == character
        }
        if let mark = NoteMark.allCases.first(where: { matches($0.shortcut) }) {
            toggle(mark)
            return true
        }
        if let kind = NoteParagraphKind.allCases.first(where: { matches($0.shortcut) }) {
            apply(kind)
            return true
        }
        if flags == .command, character == "k" {
            orderFrontLinkPanel(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        noteCoordinator?.context.endEditingSketch()
        if isEditable, let paragraph = checkbox(at: convert(event.locationInWindow, from: nil)) {
            setFormat({ $0.with(checked: !$0.checked) }, paragraphs: [paragraph])
            return
        }
        super.mouseDown(with: event)
    }

    /// The checklist paragraph whose box is at `point` (view coordinates).
    private func checkbox(at point: CGPoint) -> NSRange? {
        guard let layout = textLayoutManager, let content = textContentStorage else { return nil }
        let origin = textContainerOrigin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: local) as? NoteListFragment,
              case .checkbox = fragment.marker
        else { return nil }
        let top = fragment.textLineFragments.first?.typographicBounds.minY ?? 0
        let hit = fragment.hitRect.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY + top)
        guard hit.contains(local), let range = fragment.textElement?.elementRange else { return nil }
        let start = content.offset(from: content.documentRange.location, to: range.location)
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: min(start, (string as NSString).length), length: 0))
        return paragraph.length > 0 ? paragraph : nil
    }

    // MARK: Pasteboard

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.blocksType, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let storage = textStorage else { return false }
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return false }
        let selection = NSMutableAttributedString()
        for range in ranges { selection.append(storage.attributedSubstring(from: range)) }
        let blocks = NoteDocumentReader.blocks(from: selection)
        switch type {
        case Self.blocksType:
            return pboard.setString(NoteBlock.json(blocks), forType: type)
        case .string:
            // Chips as their labels ("S13", "37:59"), media as nothing.
            return pboard.setString(NoteBlock.plainText(of: blocks), forType: .string)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.blocksType, .fileURL, .png, .tiff, Self.jpegType, Self.heicType, .string]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let coordinator = noteCoordinator else { return super.readSelection(from: pboard, type: type) }
        switch type {
        case Self.blocksType:
            guard let json = pboard.string(forType: type), let blocks = try? NoteBlock.decode(json), !blocks.isEmpty else { return false }
            coordinator.paste(blocks)
            return true
        case .fileURL:
            let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            let images = urls.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image)) == true }
            guard !images.isEmpty else {
                // Other files: their names as text.
                let names = urls.map(\.lastPathComponent).joined(separator: " ")
                guard !names.isEmpty else { return false }
                insertText(names, replacementRange: selectedRange())
                return true
            }
            coordinator.importImages(images)
            return true
        case .png, .tiff, Self.jpegType, Self.heicType:
            guard let data = pboard.data(forType: type) else { return false }
            let ext = UTType(type.rawValue)?.preferredFilenameExtension
            coordinator.importImageData(data, fileExtension: type == .tiff ? "tiff" : ext)
            return true
        case .string:
            guard let text = pboard.string(forType: .string) else { return false }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            insertText(normalized, replacementRange: selectedRange())
            return true
        default:
            return super.readSelection(from: pboard, type: type)
        }
    }
}

/// The editor's glue: loads the note into the text view, saves it through the session, keeps
/// paragraphs whole after edits, draws list markers and reports focus and height.
@MainActor
final class NoteEditorCoordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate {
    nonisolated let metrics: NoteMetrics
    let context: NoteEditorContext
    let typesetter: NoteTypesetter
    let builder: NoteDocumentBuilder
    var session: NoteSession?
    weak var textView: NoteTextView?
    var onFocus: ((Bool) -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    var controller: NoteEditorController?
    var lastFocusRequest = 0
    private var lastHeight: CGFloat = -1
    private var editedParagraphs: NSRange?
    private var paragraphCountChanged = false

    init(metrics: NoteMetrics, context: NoteEditorContext) {
        self.metrics = metrics
        self.context = context
        typesetter = NoteTypesetter(metrics: metrics)
        builder = NoteDocumentBuilder(typesetter: NoteTypesetter(metrics: metrics), context: context)
    }

    // MARK: Loading

    func load(_ blocks: [NoteBlock], into textView: NoteTextView, startsWith: NoteParagraphKind) {
        let text = builder.document(blocks)
        textView.textStorage?.setAttributedString(text)
        let format: BlockFormat = blocks.isEmpty ? BlockFormat.make(startsWith, from: .body) : .body
        if text.length > 0 {
            let last = text.attributes(at: text.length - 1, effectiveRange: nil)
            textView.typingAttributes = last.filter { $0.key != .attachment && $0.key != .link }
        } else {
            textView.typingAttributes = typesetter.paragraphAttributes(format)
        }
        textView.setSelectedRange(NSRange(location: text.length, length: 0))
    }

    // MARK: Attributes

    /// `attributes` (typing or a run's) moved into `format`, keeping the run's character styles.
    func typingAttributes(_ format: BlockFormat, keeping attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        typesetter.attributes(format, marks: NoteTypesetter.marks(attributes))
    }

    /// Sets the paragraph's format on every run of it, keeping their character styles, links and
    /// attachments.
    func apply(_ format: BlockFormat, to paragraph: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttributes(in: paragraph) { attributes, range, _ in
            var next = typesetter.attributes(format, marks: NoteTypesetter.marks(attributes))
            if let attachment = attributes[.attachment] { next[.attachment] = attachment }
            if let link = attributes[.link] { next[.link] = link }
            storage.setAttributes(next, range: range)
        }
    }

    static func key(for mark: NoteMark) -> NSAttributedString.Key {
        switch mark {
        case .bold: .noteBold
        case .italic: .noteItalic
        case .underline: .noteUnderline
        case .strikethrough: .noteStrikethrough
        case .highlight: .noteHighlight
        }
    }

    /// A run's attributes with `mark` on or off (the font follows bold and italic).
    func attributes(_ attributes: [NSAttributedString.Key: Any], setting mark: NoteMark, on: Bool) -> [NSAttributedString.Key: Any] {
        var marks = NoteTypesetter.marks(attributes).filter { $0 != mark.mark }
        if on { marks.append(mark.mark) }
        let format = attributes[.noteBlock] as? BlockFormat ?? .body
        var next = typesetter.attributes(format, marks: marks)
        if let link = attributes[.link] { next[.link] = link }
        return next
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let string = textView.string as NSString
        let replaced = affectedCharRange.length > 0 ? string.substring(with: affectedCharRange) : ""
        if replaced.contains(where: \.isNewline) || (replacementString ?? "").contains(where: \.isNewline) {
            paragraphCountChanged = true
        }
        let changed = NSRange(location: affectedCharRange.location, length: (replacementString as NSString?)?.length ?? affectedCharRange.length)
        editedParagraphs = editedParagraphs.map { NSUnionRange($0, changed) } ?? changed
        // ln: typed or replaced words are the student's (a style change keeps Claude's grey).
        if replacementString != nil { typedRange = typedRange.map { NSUnionRange($0, changed) } ?? changed }
        return true
    }

    /// The text the student typed or changed since the last change was handled.
    private var typedRange: NSRange?

    /// ln: the words the student typed in or changed lose the `ai` mark (DESIGN 5.1: grey becomes
    /// normal when the student takes it), whole words, and typing goes on in the label colour.
    private func dropAIMark(in textView: NoteTextView) {
        guard let storage = textView.textStorage, var range = typedRange else { return }
        typedRange = nil
        if textView.typingAttributes[.noteAI] != nil {
            var typing = textView.typingAttributes
            typing[.noteAI] = nil
            typing[.foregroundColor] = NSColor.labelColor
            textView.typingAttributes = typing
        }
        let string = storage.string as NSString
        guard string.length > 0 else { return }
        range.location = min(range.location, string.length)
        range.length = min(range.length, string.length - range.location)
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < string.length, let scalar = UnicodeScalar(string.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        var start = range.location
        while isWord(start - 1) { start -= 1 }
        var end = NSMaxRange(range)
        while isWord(end) { end += 1 }
        let words = NSRange(location: start, length: end - start)
        guard words.length > 0 else { return }
        var touched: [NSRange] = []
        storage.enumerateAttribute(.noteAI, in: words) { value, sub, _ in
            if value as? Bool == true { touched.append(sub) }
        }
        guard !touched.isEmpty else { return }
        storage.beginEditing()
        for sub in touched {
            storage.removeAttribute(.noteAI, range: sub)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: sub)
        }
        storage.endEditing()
    }

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        // While a character is being composed (a dead key, ⌥u, an input method) its marked text is
        // left alone: the edited paragraphs are normalized, numbered and saved once it commits
        // (which changes the text again).
        guard !textView.hasMarkedText() else {
            sizeChanged()
            return
        }
        normalizeEditedParagraphs(in: textView)
        dropAIMark(in: textView)
        if paragraphCountChanged {
            paragraphCountChanged = false
            refreshNumbers(in: textView)
        }
        session?.edited()
        sizeChanged()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView, !textView.hasMarkedText() else { return }
        // At the start of a paragraph, typing takes that paragraph's format (not the previous
        // paragraph's, whose newline is before the caret).
        let selection = textView.selectedRange()
        if selection.length == 0, let storage = textView.textStorage, selection.location < storage.length {
            let paragraph = (storage.string as NSString).paragraphRange(for: selection)
            if paragraph.location == selection.location, paragraph.length > 0 {
                var attributes = storage.attributes(at: selection.location, effectiveRange: nil)
                attributes[.attachment] = nil
                attributes[.link] = nil
                textView.typingAttributes = attributes
            }
        }
        controller?.selectionChanged(format: textView.format(of: textView.selectedParagraphs().last ?? NSRange()).paragraphKind)
    }

    /// Every paragraph an edit touched takes its first character's format (a merged paragraph
    /// keeps the first one's, Notes-like); pasted or typed text never carries another one.
    private func normalizeEditedParagraphs(in textView: NoteTextView) {
        guard let storage = textView.textStorage, var edited = editedParagraphs else { return }
        editedParagraphs = nil
        let length = storage.length
        guard length > 0 else { return }
        edited.location = min(edited.location, length - 1)
        edited.length = min(edited.length, length - edited.location)
        let string = storage.string as NSString
        let range = string.paragraphRange(for: edited)
        var location = range.location
        var began = false
        while location < NSMaxRange(range) {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let format = storage.attribute(.noteBlock, at: paragraph.location, effectiveRange: nil) as? BlockFormat ?? .body
            var uniform = true
            storage.enumerateAttribute(.noteBlock, in: paragraph) { value, _, stop in
                if (value as? BlockFormat)?.isEqual(format) != true {
                    uniform = false
                    stop.pointee = true
                }
            }
            guard !uniform else { continue }
            if !began {
                storage.beginEditing()
                began = true
            }
            apply(format, to: paragraph, in: storage)
        }
        if began { storage.endEditing() }
    }

    /// Numbers follow their list: after ↩ or ⌫ across lines, the items after it are drawn again.
    private func refreshNumbers(in textView: NoteTextView) {
        guard let storage = textView.textStorage, let layout = textView.textLayoutManager else { return }
        var hasNumbers = false
        storage.enumerateAttribute(.noteBlock, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if (value as? BlockFormat)?.kind == .numbered {
                hasNumbers = true
                stop.pointee = true
            }
        }
        if hasNumbers { layout.invalidateLayout(for: layout.documentRange) }
    }

    // MARK: NSTextLayoutManagerDelegate

    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let format = paragraph.attributedString.attribute(.noteBlock, at: 0, effectiveRange: nil) as? BlockFormat,
              format.isList
        else { return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange) }
        let marker: NoteListFragment.Marker = switch format.kind {
        case .checklist: .checkbox(checked: format.checked)
        case .numbered: .number(Self.number(of: paragraph, level: format.level, in: textLayoutManager.textContentManager))
        default: .bullet(level: format.level)
        }
        return NoteListFragment(
            textElement: textElement, range: textElement.elementRange, marker: marker,
            indent: metrics.listIndent * CGFloat(format.level + 1), font: NSFont.systemFont(ofSize: metrics.bodySize)
        )
    }

    /// The item's number: 1 + the numbered items right before it at its level (deeper items in
    /// between are skipped; anything else ends the count).
    nonisolated static func number(of paragraph: NSTextParagraph, level: Int, in manager: NSTextContentManager?) -> Int {
        guard let manager, let range = paragraph.elementRange else { return 1 }
        var count = 1
        manager.enumerateTextElements(from: range.location, options: [.reverse]) { element in
            guard let other = element as? NSTextParagraph, let otherRange = other.elementRange else { return false }
            if otherRange.isEqual(to: range) || otherRange.location.compare(range.location) != .orderedAscending { return true }
            guard other.attributedString.length > 0,
                  let format = other.attributedString.attribute(.noteBlock, at: 0, effectiveRange: nil) as? BlockFormat,
                  format.isList
            else { return false }
            if format.level > level { return true }
            guard format.level == level, format.kind == .numbered else { return false }
            count += 1
            return true
        }
        return count
    }

    // MARK: Focus and size

    func focusChanged(_ focused: Bool) {
        controller?.focusChanged(focused, textView: textView)
        onFocus?(focused)
    }

    func sizeChanged() {
        guard let textView, let onHeight, !textView.isDocument else {
            textView?.needsLayout = true
            return
        }
        textView.needsLayout = true
        let height = textView.contentHeight()
        guard abs(height - lastHeight) > 0.5 else { return }
        lastHeight = height
        // Reported after the layout pass that asked: never while SwiftUI updates.
        Task { @MainActor in onHeight(height) }
    }

    // MARK: Inserting

    func paste(_ blocks: [NoteBlock]) {
        guard let textView else { return }
        // One plain paragraph pastes into the paragraph at the caret; more come as paragraphs.
        if blocks.count == 1, let block = blocks.first, [.paragraph, .heading, .bullet, .numbered, .checklist].contains(block.type) {
            let paragraph = textView.selectedParagraphs().last ?? NSRange(location: 0, length: 0)
            textView.insert(builder.runs(block.inlines ?? [NoteInline(text: block.text)], format: textView.format(of: paragraph)))
            return
        }
        textView.insert(builder.document(blocks))
    }

    func importImages(_ urls: [URL]) {
        guard let blobs = context.services?.blobs else { return }
        let width = imageWidth
        Task { @MainActor in
            for url in urls {
                guard let media = await Self.importImage(url: url, blobs: blobs, maxWidth: width) else { continue }
                textView?.insertInline(MediaAttachment(inline: NoteMedia.inline(media), context: context))
            }
        }
    }

    func importImageData(_ data: Data, fileExtension: String?) {
        guard let blobs = context.services?.blobs else { return }
        let width = imageWidth
        Task { @MainActor in
            guard let media = await Self.importImage(data: data, fileExtension: fileExtension, blobs: blobs, maxWidth: width) else { return }
            textView?.insertInline(MediaAttachment(inline: NoteMedia.inline(media), context: context))
        }
    }

    /// Images are as wide as the document's text at most.
    private var imageWidth: Double {
        NoteMedia.maximumDisplayWidth
    }

    @concurrent
    nonisolated private static func importImage(url: URL, blobs: BlobStore, maxWidth: Double) async -> NoteAttachment? {
        do {
            return try NoteMedia.importImage(at: url, blobs: blobs, maxWidth: maxWidth)
        } catch {
            NotesLog.logger.error("Importing an image failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @concurrent
    nonisolated private static func importImage(data: Data, fileExtension: String?, blobs: BlobStore, maxWidth: Double) async -> NoteAttachment? {
        do {
            return try NoteMedia.importImage(data: data, fileExtension: fileExtension, blobs: blobs, maxWidth: maxWidth)
        } catch {
            NotesLog.logger.error("Importing an image failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func insertSketch() {
        guard let textView, let blobs = context.services?.blobs else { return }
        let width = textView.textContainer?.size.width ?? 480
        let drawing = NoteMedia.newSketch(width: width)
        guard let media = try? NoteMedia.storeSketch(drawing, blobs: blobs) else { return }
        let attachment = MediaAttachment(sketch: media, drawing: drawing, context: context)
        textView.insertInline(attachment)
        context.beginEditing(ObjectIdentifier(attachment))
    }
}

/// The SwiftUI side of the Mac editor: a scrolling document (Notes screen) or a text view as tall
/// as its text (Review's inspector).
struct NoteTextEditor: NSViewRepresentable {
    let session: NoteSession?
    let blocks: [NoteBlock]
    let stamp: String?
    let style: NoteEditorStyle
    let startsWith: NoteParagraphKind
    let controller: NoteEditorController
    let context: NoteEditorContext
    let trailingTime: Double?
    let focusRequest: Int
    let onFocus: ((Bool) -> Void)?
    let onHeight: ((CGFloat) -> Void)?
    /// Puts the caret in the editor once it is in its window (a new note).
    var startsFocused = false

    @Environment(\.studyServices) private var services
    @Environment(\.openDestination) private var openDestination

    init(
        session: NoteSession?, blocks: [NoteBlock], stamp: String?, style: NoteEditorStyle, startsWith: NoteParagraphKind,
        controller: NoteEditorController, context: NoteEditorContext, trailingTime: Double?, focusRequest: Int,
        onFocus: ((Bool) -> Void)?, onHeight: ((CGFloat) -> Void)?
    ) {
        self.session = session
        self.blocks = blocks
        self.stamp = stamp
        self.style = style
        self.startsWith = startsWith
        self.controller = controller
        self.context = context
        self.trailingTime = trailingTime
        self.focusRequest = focusRequest
        self.onFocus = onFocus
        self.onHeight = onHeight
    }

    func makeCoordinator() -> NoteEditorCoordinator {
        NoteEditorCoordinator(metrics: context.metrics, context: context)
    }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.controller = controller
        coordinator.onFocus = onFocus
        coordinator.onHeight = onHeight
        coordinator.lastFocusRequest = focusRequest
        configure(coordinator.context)

        let textView = NoteTextView(usingTextLayoutManager: true)
        coordinator.textView = textView
        textView.noteCoordinator = coordinator
        textView.delegate = coordinator
        textView.textLayoutManager?.delegate = coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = session != nil
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = session != nil
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFindBar = style == .document
        textView.isIncrementalSearchingEnabled = style == .document
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.setAccessibilityLabel(String(localized: "Note"))
        coordinator.load(blocks, into: textView, startsWith: startsWith)
        textView.stampLabel.stringValue = stamp ?? ""
        session?.contentProvider = { [weak textView] in
            guard let storage = textView?.textStorage else { return nil }
            return NoteDocumentReader.blocks(from: storage)
        }
        controller.attach(textView)
        updateAccessory(textView, coordinator: coordinator)
        if startsFocused {
            Task { @MainActor [weak textView] in
                for _ in 0..<10 {
                    if let textView, let window = textView.window {
                        window.makeFirstResponder(textView)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        }

        guard style == .document else {
            textView.isVerticallyResizable = false
            textView.isHorizontallyResizable = false
            textView.textContainerInset = .zero
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.size = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
            return textView
        }
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        textView.isDocument = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // The column's width is set by `updateInsets` (at most 680), not by the view's.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onFocus = onFocus
        coordinator.onHeight = onHeight
        configure(coordinator.context)
        guard let textView = coordinator.textView else { return }
        if let stamp, textView.stampLabel.stringValue != stamp {
            textView.stampLabel.stringValue = stamp
            textView.needsLayout = true
        }
        updateAccessory(textView, coordinator: coordinator)
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            Task { @MainActor [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: NoteEditorCoordinator) {
        coordinator.context.endEditingSketch()
        // The body as it is now, before the text goes away: a pending change is never lost.
        coordinator.session?.saveNow()
        if let textView = coordinator.textView {
            textView.undoManager?.removeAllActions(withTarget: textView)
            if let storage = textView.textStorage { textView.undoManager?.removeAllActions(withTarget: storage) }
            if textView.window?.firstResponder === textView { coordinator.focusChanged(false) }
            coordinator.controller?.detach(textView)
        }
    }

    private func configure(_ editorContext: NoteEditorContext) {
        editorContext.services = services
        editorContext.open = openDestination
        editorContext.isEditable = session != nil
        let session = session
        editorContext.edited = { session?.edited() }
    }

    private func updateAccessory(_ textView: NoteTextView, coordinator: NoteEditorCoordinator) {
        guard let trailingTime else {
            if textView.trailingAccessory != nil { textView.trailingAccessory = nil }
            return
        }
        let source = SourceRef(kind: .transcript, lectureID: coordinator.context.lectureID, time: trailingTime)
        let editorContext = coordinator.context
        let chip = TimeChip(trailingTime) { editorContext.activate(.time(source)) }
        if let host = textView.trailingAccessory as? NSHostingView<TimeChip> {
            host.rootView = chip
        } else {
            textView.trailingAccessory = NSHostingView(rootView: chip)
        }
        textView.needsLayout = true
    }
}
#endif
