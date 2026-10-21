#if os(macOS)
import AppKit
import NotesUI
import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// The notes' text: a read-only `NSTextView` on TextKit 2 (docs/plan-lecture-notes.md §3), so a
/// selection runs across paragraphs and figures and Copy, Look Up and Translate come with it. A
/// settled selection gets the glass capsule [highlighter] [Ask]; its context menu starts with
/// Ask… and Highlight / Remove Highlight; ⌘K and ⇧⌘E work while it has focus. Section headings
/// hang a fold chevron in the margin on hover (always while folded).
final class NotesTextView: NSTextView {
    /// The room before (and after) the text for the fold chevrons.
    static let chevronMargin: CGFloat = 18

    weak var notesCoordinator: NotesTextCoordinator?
    private var hoveredHeading: String?
    private var trackingArea: NSTrackingArea?
    private var settleTask: Task<Void, Never>?

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { notesCoordinator?.widthChanged() }
    }

    override func layout() {
        super.layout()
        notesCoordinator?.positionOverlays()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notesCoordinator?.observeScrolling()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { notesCoordinator?.focusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { notesCoordinator?.focusChanged(false) }
        return resigned
    }

    // MARK: Mouse and keys

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let key = notesCoordinator?.chevron(at: point) {
            notesCoordinator?.toggleFold(key)
            return
        }
        notesCoordinator?.hideCapsule()
        // NSTextView tracks a drag selection until the button goes up.
        super.mouseDown(with: event)
        notesCoordinator?.selectionSettled()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let heading = notesCoordinator?.heading(at: point)
        if heading != hoveredHeading {
            hoveredHeading = heading
            notesCoordinator?.hoveredHeading = heading
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredHeading != nil {
            hoveredHeading = nil
            notesCoordinator?.hoveredHeading = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        // A selection made with ⇧-arrows settles 400 ms after the last key.
        guard event.modifierFlags.contains(.shift) else { return }
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.notesCoordinator?.selectionSettled()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        notesCoordinator?.hideCapsule()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let character = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, character == "k" {
            notesCoordinator?.controller?.ask()
            return true
        }
        if flags == [.command, .shift], character == "e" {
            notesCoordinator?.controller?.toggleHighlight()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        notesCoordinator?.prepare(menu, at: convert(event.locationInWindow, from: nil))
        return menu
    }

    // MARK: Copy (attachments as their words)

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textStorage else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map { NotesTextCoordinator.plainText(of: storage, in: $0) }
            .joined(separator: "\n")
        guard !text.isEmpty else { return false }
        return pboard.setString(text, forType: .string)
    }
}

/// The document's glue: draws the input as units (only what changed is replaced, so streaming
/// never rebuilds what is on screen), keeps the height, the marks drawn while hovered or asked
/// about, the chevrons and the capsule, and the Ask popover.
@MainActor
final class NotesTextCoordinator: NSObject, NSTextViewDelegate, NSTextLayoutManagerDelegate, NotesDocumentActions {
    weak var textView: NotesTextView?
    weak var controller: LectureNotesController?
    var onHeight: ((CGFloat) -> Void)?
    private(set) var input: NotesDocumentInput?
    private var units: [NotesUnit] = []
    private var build = NotesBuild()
    private var renderings: [LectureNotesStyle: NoteTextRendering] = [:]
    private let anchors = NotesAnchorCache()
    private var lastHeight: CGFloat = -1
    private var chevronViews: [String: NSView] = [:]
    private var capsule: NSView?
    private var popover: NSPopover?
    private var askSession: AskSession?
    /// Renders: the preview's popover drawn in place, its passage marked.
    private var previewPopover: NSView?
    private var previewPassage: NSRange?
    private var previewTask: Task<Void, Never>?
    /// Renders: the capsule on an opaque surface (an off-screen window draws no glass).
    private var opaqueCapsule = false
    private var observedClip: NSClipView?
    private var pendingInvalidate = false
    private var hoveredMark: LectureNotesMark.ID?
    private var lastWidth: CGFloat = 0
    var hoveredHeading: String? {
        didSet { positionOverlays() }
    }

    var services: StudyServices? { controller?.services }

    // MARK: Drawing the input

    func rendering(for input: NotesDocumentInput) -> NoteTextRendering {
        if let existing = renderings[input.style] { return existing }
        let controller = controller
        let rendering = NoteTextRendering(
            style: input.style == .page ? .document : .inspector, services: controller?.services, lectureID: input.lectureID,
            professor: input.professor, open: controller?.openDestination ?? OpenDestinationAction { _ in },
            onLink: { link in
                guard let controller else { return false }
                switch link {
                case .slide(let source):
                    guard let page = source.pageNumber else { return false }
                    controller.open(.slide(lecture: source.lectureID ?? input.lectureID, page: page))
                case .time(let source):
                    guard let time = source.time else { return false }
                    controller.open(.moment(lecture: source.lectureID ?? input.lectureID, recording: source.recordingID, seconds: time))
                }
                return true
            }
        )
        renderings[input.style] = rendering
        return rendering
    }

    func apply(_ input: NotesDocumentInput) {
        guard input != self.input, let textView, let storage = textView.textStorage else { return }
        self.input = input
        let width = textView.textContainer?.size.width ?? 600
        lastWidth = width
        let builder = NotesDocumentBuilder(
            input: input, containerWidth: width, actions: self, noteRendering: rendering(for: input), anchors: anchors
        )
        let next = builder.build()
        // Keep the units that did not change (their text and attachments stay on screen).
        var first = 0
        while first < min(units.count, next.units.count), units[first].signature == next.units[first].signature { first += 1 }
        if first < units.count || first < next.units.count {
            let keptLength = units[..<first].reduce(0) { $0 + $1.text.length }
            let replacement = NSMutableAttributedString()
            for unit in next.units[first...] { replacement.append(unit.text) }
            let range = NSRange(location: keptLength, length: max(0, storage.length - keptLength))
            let selection = textView.selectedRange()
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: replacement)
            storage.endEditing()
            if NSMaxRange(selection) <= keptLength { textView.setSelectedRange(selection) }
            units = Array(units[..<first]) + Array(next.units[first...])
        }
        build = next
        applyRenderingMarks()
        controller?.syncOrphans(found: next.found, orphaned: next.orphaned)
        sizeChanged()
        positionOverlays()
    }

    /// The column's width changed: the headings' chips stay at the line's end.
    func widthChanged() {
        guard let textView, let storage = textView.textStorage else { return }
        let width = textView.textContainer?.size.width ?? 600
        guard abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        storage.beginEditing()
        storage.enumerateAttribute(.notesHeading, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let mutable = style.mutableCopy() as? NSMutableParagraphStyle
            else { return }
            mutable.tabStops = [NSTextTab(textAlignment: .right, location: max(40, width), options: [:])]
            storage.addAttribute(.paragraphStyle, value: mutable, range: range)
        }
        storage.endEditing()
        sizeChanged()
    }

    // MARK: Height and viewport

    func sizeChanged() {
        guard let textView, let layout = textView.textLayoutManager else { return }
        layout.ensureLayout(for: layout.documentRange)
        let height = ceil(layout.usageBoundsForTextContainer.height + textView.textContainerInset.height * 2)
        textView.needsLayout = true
        guard abs(height - lastHeight) > 0.5 else { return }
        lastHeight = height
        let onHeight = onHeight
        Task { @MainActor in onHeight?(height) }
    }

    func attachmentChangedSize() {
        guard !pendingInvalidate else { return }
        pendingInvalidate = true
        Task { @MainActor [weak self] in
            guard let self, let layout = self.textView?.textLayoutManager else { return }
            self.pendingInvalidate = false
            layout.invalidateLayout(for: layout.documentRange)
            self.sizeChanged()
            self.positionOverlays()
        }
    }

    /// The text view sits in its screen's scroll view (not its own): lay out what scrolls into view,
    /// and a scroll takes the capsule away.
    func observeScrolling() {
        guard let clip = textView?.enclosingScrollView?.contentView, clip !== observedClip else { return }
        if let observedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip) }
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled(_:)), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipScrolled(_ notification: Notification) {
        textView?.textLayoutManager?.textViewportLayoutController.layoutViewport()
        if capsule != nil { hideCapsule() }
    }

    /// Scrolls the screen so the section's heading is at the top (Review's Follow).
    /// Waits (briefly) until the view is as tall as its text: SwiftUI sizes it a moment after the
    /// text is laid out.
    func scroll(toSection key: String) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self, let textView = self.textView, let rect = self.headingRect(key) else { return }
                if textView.bounds.height >= rect.maxY, textView.window != nil {
                    let visible = textView.enclosingScrollView?.contentView.bounds.height ?? 400
                    textView.scrollToVisible(CGRect(x: rect.minX, y: max(0, rect.minY - 10), width: 1, height: max(visible - 20, rect.height)))
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
        }
    }

    private var scrollTask: Task<Void, Never>?

    // MARK: Marks drawn on the fly (the passage of an Ask, a hovered kept answer)

    private func applyRenderingMarks() {
        guard let textView, let layout = textView.textLayoutManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
        var ranges: [NSRange] = []
        if let askSession, popover?.isShown == true { ranges.append(askSession.passage.range) }
        if let previewPassage { ranges.append(previewPassage) }
        if let hoveredMark, let range = build.passages[hoveredMark] { ranges.append(range) }
        for range in ranges {
            guard let textRange = textRange(range) else { continue }
            layout.addRenderingAttribute(.backgroundColor, value: NotesNSInk.accentSoft, for: textRange)
        }
    }

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let content = textView?.textContentStorage, let storage = textView?.textStorage,
              range.location >= 0, NSMaxRange(range) <= storage.length,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func keptAnswerHovered(_ mark: LectureNotesMark.ID, _ hovered: Bool) {
        hoveredMark = hovered ? mark : (hoveredMark == mark ? nil : hoveredMark)
        applyRenderingMarks()
    }

    // MARK: Headings and chevrons

    /// A heading's line in the view's coordinates.
    private func headingRect(_ key: String) -> CGRect? {
        guard let textView, let layout = textView.textLayoutManager else { return nil }
        var offset = 0
        for unit in units {
            if unit.role == .heading, unit.section == key {
                guard let range = textRange(NSRange(location: offset, length: 0)),
                      let fragment = layout.textLayoutFragment(for: range.location)
                else { return nil }
                let frame = fragment.layoutFragmentFrame
                let line = fragment.textLineFragments.first?.typographicBounds ?? CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                let origin = textView.textContainerOrigin
                return CGRect(x: origin.x + frame.minX, y: origin.y + frame.minY + line.minY, width: frame.width, height: line.height)
            }
            offset += unit.text.length
        }
        return nil
    }

    func heading(at point: CGPoint) -> String? {
        for unit in units where unit.role == .heading {
            guard let rect = headingRect(unit.section) else { continue }
            if point.y >= rect.minY - 4, point.y <= rect.maxY + 4 { return unit.section }
        }
        return nil
    }

    func chevron(at point: CGPoint) -> String? {
        for (key, view) in chevronViews where !view.isHidden && view.frame.insetBy(dx: -3, dy: -3).contains(point) {
            return key
        }
        return nil
    }

    func toggleFold(_ key: String) {
        controller?.toggleFold(key)
    }

    func positionOverlays() {
        guard let textView, let input else { return }
        let headings = Set(units.filter { $0.role == .heading }.map(\.section))
        for (key, view) in chevronViews where !headings.contains(key) {
            view.removeFromSuperview()
            chevronViews[key] = nil
        }
        for key in headings {
            let folded = input.folded.contains(key)
            let chevron = FoldChevron(isFolded: folded) { [weak self] in self?.toggleFold(key) }
            let view: NSView
            if let existing = chevronViews[key] as? NSHostingView<FoldChevron> {
                existing.rootView = chevron
                view = existing
            } else {
                let host = NSHostingView(rootView: chevron)
                textView.addSubview(host)
                chevronViews[key] = host
                view = host
            }
            guard let rect = headingRect(key) else {
                view.isHidden = true
                continue
            }
            let size: CGFloat = 14
            view.frame = CGRect(x: rect.minX - NotesTextView.chevronMargin + 1, y: rect.midY - size / 2, width: size, height: size)
            view.isHidden = !(folded || hoveredHeading == key)
        }
        positionCapsule()
    }

    // MARK: Focus, selection, capsule

    func focusChanged(_ focused: Bool) {
        controller?.isFocused = focused
        if !focused, popover?.isShown != true { hideCapsule() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        controller?.selection = currentSelection()
        // A new selection takes the capsule away until it settles.
        if capsule != nil, NSApp.currentEvent?.type != .leftMouseUp { hideCapsule() }
    }

    func clearSelection() {
        guard let textView else { return }
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        hideCapsule()
    }

    /// The selection as a passage: plain text, its part, its context and the highlights it
    /// touches. A selection over several parts is clamped to the one it starts in.
    func currentSelection() -> NotesSelection? {
        guard let textView, let storage = textView.textStorage else { return nil }
        var range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        guard let key = storage.attribute(.notesSection, at: range.location, effectiveRange: nil) as? String else { return nil }
        // The part's text (its body units).
        var offset = 0
        var partStart: Int?
        var partEnd = 0
        for unit in units {
            if unit.section == key, unit.role != .heading {
                if partStart == nil { partStart = offset }
                partEnd = offset + unit.text.length
            }
            offset += unit.text.length
        }
        guard let start = partStart else { return nil }
        let clampedEnd = min(NSMaxRange(range), partEnd)
        let clampedStart = max(range.location, start)
        guard clampedEnd > clampedStart else { return nil }
        range = NSRange(location: clampedStart, length: clampedEnd - clampedStart)
        let exact = Self.plain(storage.attributedSubstring(from: range).string)
        guard !exact.isEmpty else { return nil }
        let before = Self.plain((storage.string as NSString).substring(with: NSRange(location: start, length: range.location - start)))
        let after = Self.plain((storage.string as NSString).substring(with: NSRange(location: NSMaxRange(range), length: partEnd - NSMaxRange(range))))
        let highlights = build.highlights.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.id)
        return NotesSelection(
            range: range, exact: String(exact.prefix(LectureNotesMark.exactLimit)), prefix: String(before.suffix(LectureNotesMark.contextLength)),
            suffix: String(after.prefix(LectureNotesMark.contextLength)), sectionKey: key, start: range.location - start,
            end: NSMaxRange(range) - start, highlights: Array(Set(highlights))
        )
    }

    /// Displayed text without attachment characters, single spaces.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: #"[  ]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A selection settled (mouse up, 400 ms after the last ⇧-arrow): the capsule floats over it.
    func selectionSettled() {
        guard let selection = currentSelection(), selection.hasWords, let textView else {
            hideCapsule()
            return
        }
        controller?.selection = selection
        // A new passage: the one taken to the chat earlier stops going with the next message.
        controller?.clearChatPassage()
        if capsule == nil {
            let host = NSHostingView(rootView: capsuleView())
            textView.addSubview(host)
            capsule = host
        } else if let host = capsule as? NSHostingView<SelectionCapsule> {
            host.rootView = capsuleView()
        }
        positionCapsule()
    }

    private func capsuleView() -> SelectionCapsule {
        let controller = controller
        return SelectionCapsule(
            canAsk: controller?.asker != nil,
            opaque: opaqueCapsule,
            highlight: { controller?.toggleHighlight() },
            ask: { controller?.ask() }
        )
    }

    /// 6 pt above the end of the selection's last line.
    private func positionCapsule() {
        guard let capsule, let textView, let layout = textView.textLayoutManager, let selection = controller?.selection,
              let range = textRange(selection.range)
        else { return }
        var last: CGRect?
        layout.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            if frame.width > 0 { last = frame }
            return true
        }
        guard let segment = last else { return }
        let size = capsule.fittingSize
        let origin = textView.textContainerOrigin
        let x = min(max(origin.x + segment.maxX + 6 - size.width, 0), textView.bounds.width - size.width)
        let y = origin.y + segment.minY - 6 - size.height
        capsule.frame = CGRect(x: x, y: max(0, y), width: size.width, height: size.height)
    }

    func hideCapsule() {
        capsule?.removeFromSuperview()
        capsule = nil
    }

    // MARK: Menu

    func prepare(_ menu: NSMenu, at point: CGPoint) {
        var index = 0
        func insert(_ item: NSMenuItem) {
            menu.insertItem(item, at: index)
            index += 1
        }
        if let selection = currentSelection(), selection.hasWords {
            controller?.selection = selection
            if controller?.asker != nil {
                let ask = NSMenuItem(title: String(localized: "Ask…"), action: #selector(menuAsk), keyEquivalent: "k")
                ask.keyEquivalentModifierMask = .command
                ask.target = self
                insert(ask)
            }
            let title = selection.highlights.isEmpty ? String(localized: "Highlight") : String(localized: "Remove Highlight")
            let highlight = NSMenuItem(title: title, action: #selector(menuHighlight), keyEquivalent: "e")
            highlight.keyEquivalentModifierMask = [.command, .shift]
            highlight.target = self
            insert(highlight)
        }
        if let note = studentNote(at: point) {
            let edit = NSMenuItem(title: String(localized: "Edit in Review"), action: #selector(menuEditInReview(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = note.id.uuidString
            insert(edit)
        }
        if index > 0, menu.items.count > index { menu.insertItem(.separator(), at: index) }
    }

    @objc private func menuAsk() { controller?.ask() }

    @objc private func menuHighlight() { controller?.toggleHighlight() }

    @objc private func menuEditInReview(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)),
              let note = input?.studentNotes.first(where: { $0.id == id })
        else { return }
        controller?.editInReview(note)
    }

    private func studentNote(at point: CGPoint) -> Note? {
        guard let textView, let storage = textView.textStorage else { return nil }
        let index = textView.characterIndexForInsertion(at: point)
        guard index < storage.length, let id = storage.attribute(.notesStudentNote, at: index, effectiveRange: nil) as? String else { return nil }
        return input?.studentNotes.first { $0.id.uuidString == id }
    }

    // MARK: Ask

    func showAsk(_ selection: NotesSelection, style: NotesAskStyle?) {
        guard let textView, let controller, let asker = controller.asker, let notes = controller.notes,
              let range = textRange(selection.range), let layout = textView.textLayoutManager
        else { return }
        hideCapsule()
        popover?.close()
        let session = AskSession(passage: selection, notesID: notes.id, lectureID: controller.lectureID, asker: asker)
        askSession = session
        var last: CGRect?
        var firstRect: CGRect?
        layout.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            if firstRect == nil { firstRect = frame }
            last = frame
            return true
        }
        let origin = textView.textContainerOrigin
        let anchor = (firstRect ?? .zero).union(last ?? .zero).offsetBy(dx: origin.x, dy: origin.y)
        let chips = controller.chips
        let view = AskPopoverView(
            session: session, chips: chips,
            open: { [weak controller] target in controller?.open(target) },
            keep: { [weak controller, weak session] exchange in
                guard let session else { return }
                controller?.keep(NotesAskExchange(question: exchange.question, answer: exchange.answer), passage: session.passage, update: exchange.update)
                session.kept.insert(exchange.id)
            },
            continueInChat: { [weak controller, weak session, weak self] in
                guard let session else { return }
                let exchange = session.exchanges.filter(\.isAnswered).map { NotesAskExchange(question: $0.question, answer: $0.answer) }
                controller?.continueInChat(passage: session.passage.exact, sectionKey: session.passage.sectionKey, exchange: exchange)
                self?.popover?.close()
            }
        )
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = NSHostingController(rootView: view)
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        applyRenderingMarks()
        if let style { session.send(style: style) }
    }

    // MARK: NotesDocumentActions

    func open(_ target: NotesChipTarget) {
        controller?.open(target)
    }

    func toggleAnswers(_ key: String) {
        controller?.toggleAnswers(key)
    }

    func writeAgain() {
        controller?.writeAgain()
    }

    func removeKept(_ mark: LectureNotesMark) {
        controller?.removeKept(mark)
    }

    func continueInChat(_ mark: LectureNotesMark) {
        controller?.continueInChat(mark)
    }

    func editInReview(_ note: Note) {
        controller?.editInReview(note)
    }

    // MARK: NSTextLayoutManagerDelegate

    nonisolated func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
            let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
            if let kind = attributes[.notesCallout] as? String {
                let dark = MainActor.assumeIsolated { self.input?.isDark ?? false }
                return NotesCalloutFragment(textElement: textElement, range: textElement.elementRange, kind: kind, isDark: dark)
            }
            if attributes[.notesStudentNote] != nil {
                let style = MainActor.assumeIsolated { self.input?.style ?? .page }
                if let fragment = NoteTextRendering.layoutFragment(
                    for: textElement, in: textLayoutManager, style: style == .page ? .document : .inspector
                ) {
                    return fragment
                }
            }
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    // MARK: Copy

    static func plainText(of storage: NSTextStorage, in range: NSRange) -> String {
        var text = ""
        storage.enumerateAttribute(.attachment, in: range) { value, sub, _ in
            if let value {
                if let hosted = (value as? NoteTextAttachment)?.content as? NotesAttachment {
                    let words = hosted.plainText
                    if !words.isEmpty { text += words }
                } else if let image = value as? PlainTextAttachment {
                    text += image.plainText
                }
            } else {
                text += (storage.string as NSString).substring(with: sub)
            }
        }
        return text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
    }
}

extension NotesTextCoordinator: NSPopoverDelegate {
    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            askSession?.close()
            askSession = nil
            popover = nil
            applyRenderingMarks()
        }
    }
}

// MARK: - Renders (`LectureNotesPreview`)

extension NotesTextCoordinator {
    /// Renders only: once the passage is laid out and the view as tall as its text, scrolls it to a
    /// third of the screen, then selects it and floats the capsule over it, or draws the Ask popover
    /// in place under it with its one exchange (an off-screen window draws no popover).
    func showPreview(_ preview: LectureNotesPreview) {
        guard let text = preview.passage ?? preview.reveal else { return }
        previewTask?.cancel()
        previewTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let textView = self.textView, let storage = textView.textStorage else { return }
                let found = (storage.string as NSString).range(of: text)
                guard found.location != NSNotFound, textView.window != nil, let frame = self.frame(of: found),
                      textView.bounds.height >= frame.maxY
                else { continue }
                let visible = textView.enclosingScrollView?.contentView.bounds.height ?? 600
                textView.scrollToVisible(CGRect(x: frame.minX, y: max(0, frame.minY - visible / 3), width: 1, height: max(visible - 40, frame.height)))
                // A scroll takes the capsule away: select once it has settled.
                try? await Task.sleep(for: .milliseconds(300))
                guard preview.passage != nil else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(found)
                self.opaqueCapsule = true
                if preview.question != nil {
                    self.drawPreviewPopover(preview, below: frame)
                } else {
                    self.selectionSettled()
                }
                return
            }
        }
    }

    /// The text of `range` in the view's coordinates.
    private func frame(of range: NSRange) -> CGRect? {
        guard let textView, let layout = textView.textLayoutManager, let textRange = textRange(range) else { return nil }
        var union: CGRect?
        layout.enumerateTextSegments(in: textRange, type: .selection, options: []) { _, frame, _, _ in
            if frame.width > 0 { union = union.map { $0.union(frame) } ?? frame }
            return true
        }
        let origin = textView.textContainerOrigin
        return union?.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func drawPreviewPopover(_ preview: LectureNotesPreview, below frame: CGRect) {
        guard let textView, let controller, let notes = controller.notes, let asker = controller.asker,
              let selection = currentSelection()
        else { return }
        hideCapsule()
        previewPopover?.removeFromSuperview()
        let session = AskSession(passage: selection, notesID: notes.id, lectureID: controller.lectureID, asker: asker)
        session.field = preview.question ?? ""
        session.send()
        let view = AskPopoverView(session: session, chips: controller.chips, open: { _ in }, keep: { _ in }, continueInChat: {})
            .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        let host = NSHostingView(rootView: view)
        textView.addSubview(host)
        previewPopover = host
        previewPassage = selection.range
        applyRenderingMarks()
        Task { @MainActor [weak host, weak textView] in
            // The answer arrives on the next turn: size the popover after it.
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(150))
                guard let host, let textView else { return }
                let size = host.fittingSize
                let x = min(max(frame.midX - size.width / 2, 0), max(0, textView.bounds.width - size.width))
                host.frame = CGRect(x: x, y: frame.maxY + 8, width: size.width, height: size.height)
            }
        }
    }
}

/// The fold chevron hung before a heading (Notes' folding headings): right while folded, down
/// while open (shown on hover).
struct FoldChevron: View {
    let isFolded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isFolded ? 0 : 90))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isFolded ? "Expand Section" : "Collapse Section"))
    }
}

/// The glass capsule over a settled selection: [highlighter] [Ask] (Ask only with Claude Code).
struct SelectionCapsule: View {
    let canAsk: Bool
    /// Renders only (`LectureNotesPreview`): the system's content surface instead of glass.
    var opaque = false
    let highlight: () -> Void
    let ask: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: highlight) {
                Image(systemName: "highlighter")
                    .frame(width: 30, height: 26)
                    .contentShape(Capsule())
            }
            .help(Text("Highlight"))
            .accessibilityLabel(Text("Highlight"))
            if canAsk {
                Button(action: ask) {
                    Text("Ask")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .contentShape(Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(3)
        .modifier(CapsuleSurface(opaque: opaque))
        .fixedSize()
    }
}

/// The capsule's glass, or (renders) an opaque surface with the glass's ring and shadow.
private struct CapsuleSurface: ViewModifier {
    let opaque: Bool

    func body(content: Content) -> some View {
        if opaque {
            content
                .background(.background, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        } else {
            content.glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

/// The SwiftUI side: the text view as tall as its text.
struct NotesTextHost: NSViewRepresentable {
    let input: NotesDocumentInput
    let controller: LectureNotesController
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> NotesTextCoordinator {
        NotesTextCoordinator()
    }

    func makeNSView(context: Context) -> NotesTextView {
        let coordinator = context.coordinator
        coordinator.controller = controller
        coordinator.onHeight = onHeight
        let textView = NotesTextView(usingTextLayoutManager: true)
        coordinator.textView = textView
        controller.coordinator = coordinator
        textView.notesCoordinator = coordinator
        textView.delegate = coordinator
        textView.textLayoutManager?.delegate = coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: NotesTextView.chevronMargin, height: 0)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(String(localized: "Lecture notes"))
        coordinator.apply(input)
        return textView
    }

    func updateNSView(_ view: NotesTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.controller = controller
        coordinator.onHeight = onHeight
        controller.coordinator = coordinator
        coordinator.apply(input)
    }

    static func dismantleNSView(_ view: NotesTextView, coordinator: NotesTextCoordinator) {
        coordinator.hideCapsule()
        if coordinator.controller?.isFocused == true { coordinator.focusChanged(false) }
    }
}
#endif
