#if os(macOS)
import AppKit
import Notes
import NotesUI
import SQLiteData
import StudyCore
import StudyUI
import SwiftUI

/// Your notes (nl, docs/plan-notes-layout.md §4; mockups 34–35, 40): the student's own notes for
/// the class, in a side pane beside Claude's text (the notes page) or the slide (Review's Whole
/// lecture).
///
/// - The lecture's own note first (the `Note` with the lecture and no slide), written as in Notes.
///   Empty: an area on the quiet fill that takes the caret on a click (no placeholder); the first
///   keystroke makes the note.
/// - A hairline, then one group per slide with a note or ink, in deck order: the slide's chip in a
///   34 pt leading column; beside it the slide's ink as a thumbnail (white paper in both
///   appearances), then each note of the slide, edited in place (saved 0.5 s after typing stops
///   and on leaving; emptied, it is deleted, Edit ▸ Undo brings it back). A slide with ink and no
///   note has its empty note under the thumbnail. A chip or a thumbnail opens the slide
///   (`onOpenSlide`, else Review there).
/// - A lecture without a deck: its notes with a moment, in time order, each after its time chip.
/// - What it follows (`YourNotesFollow`: the section being read, or the slide on screen) shares one
///   quiet fill, and the column scrolls it a third down from its top, never while the pointer is
///   over it, while one of its notes is being typed in, or within 2 s of the student scrolling it.
///   It opens there too (Review's Whole lecture on a late slide), placed at once as its rows load.
///
/// The pane's header ("Your notes", Maximize, Close) is the pane host's. The notes, chips and
/// thumbnails grow with `\.contentZoom`; thumbnails keep their width while a divider is dragged.
/// An Edit as Note copy (Claude's words) is not listed. Every note is written when the column goes
/// away. Esc ends typing.
///
/// Its inputs are closures read in `body`: in a pane the column is drawn in another hosting view
/// than the screen, and Observation follows what they read (the screen's `@Observable` state).
public struct YourNotesColumn: View {
    private nonisolated static let space = "yourNotes"

    private let lectureID: Lecture.ID
    private let sections: @MainActor () -> [LectureNotesSection]
    private let follow: @MainActor () -> YourNotesFollow
    private let onOpenSlide: ((Int) -> Void)?
    private let onEditingChange: (Bool) -> Void

    @Fetch private var rows: YourNotesRows
    @Environment(\.studyServices) private var services
    @Environment(\.contentZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The notes being typed in (their sessions).
    @State private var focused: Set<Note.ID> = []
    /// While a note is being typed in, its group stays and nothing is drawn again under it.
    @State private var frozen: Frozen?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var position = ScrollPosition(edge: .top)
    @State private var visible: CGRect = .zero
    @State private var isHovering = false
    @State private var userScrolledAt = Date.distantPast
    /// What it follows is to be scrolled into view: from the start (it opens there) and after each
    /// change of what it follows, until one placement was decided.
    @State private var pendingScroll = true
    /// While its rows load and grow (editors made as they appear), the opening placement is taken
    /// again as the groups move, at once.
    @State private var appearedAt = Date()

    /// - Parameters:
    ///   - sections: the current version's sections (the notes page reads them; this column's read
    ///     leaves `lecture_notes` alone, which is written ten times a second while notes stream).
    ///   - follow: what the column marks and scrolls to.
    ///   - onOpenSlide: a slide's chip or thumbnail (Review moves its own review); nil: Review opens
    ///     at the slide.
    ///   - onEditingChange: a note in the column has focus or no longer has (the page's ↩ and the
    ///     review's keys stand down meanwhile).
    public init(
        lectureID: Lecture.ID,
        sections: @escaping @MainActor () -> [LectureNotesSection] = { [] },
        follow: @escaping @MainActor () -> YourNotesFollow,
        onOpenSlide: ((Int) -> Void)? = nil,
        onEditingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.lectureID = lectureID
        self.sections = sections
        self.follow = follow
        self.onOpenSlide = onOpenSlide
        self.onEditingChange = onEditingChange
        _rows = Fetch(wrappedValue: .empty, YourNotesRequest(lectureID: lectureID))
    }

    private struct Frozen: Equatable {
        var keys: [String: String]
        var pages: Set<Int>
        var ownKey: String
    }

    public var body: some View {
        let follow = follow()
        let items = items(sections: sections())
        let run = runRect(items, follow: follow)
        ScrollView {
            content(items)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .coordinateSpace(.named(Self.space))
                .background(alignment: .topLeading) {
                    if let run {
                        // The quiet fill as a solid token (DESIGN 3.1), as the empty note's area.
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(QuietFill())
                            .frame(width: run.width, height: run.height)
                            .offset(x: run.minX, y: run.minY)
                            .accessibilityHidden(true)
                    }
                }
        }
        .scrollIndicators(.automatic)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in visible = rect }
        .onScrollPhaseChange { old, new in
            if Self.isStudent(old) || Self.isStudent(new) { userScrolledAt = Date() }
        }
        .onHover { isHovering = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ColumnBackground() }
        .modifier(EscapeEndsTyping(isActive: !focused.isEmpty))
        .onChange(of: focused.isEmpty) { _, idle in
            frozen = idle ? nil : Frozen(keys: Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.key) }), pages: Set(items.compactMap(\.page)), ownKey: ownKey)
            onEditingChange(!idle)
        }
        .onChange(of: follow) {
            pendingScroll = true
            scrollToRun(run)
        }
        .onChange(of: run) { _, run in
            if pendingScroll { scrollToRun(run) }
        }
        .onChange(of: visible.height) {
            if pendingScroll { scrollToRun(run) }
        }
        .onDisappear {
            if !focused.isEmpty { onEditingChange(false) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Your notes"))
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ items: [Item]) -> some View {
        if rows.isLoaded, let store = services?.records {
            VStack(alignment: .leading, spacing: 0) {
                OwnNoteView(
                    anchor: NoteAnchor(courseID: rows.lecture?.courseID, lectureID: lectureID, deckID: nil, page: nil, recordingID: nil),
                    notes: ownNotes, store: store, lectureID: lectureID, zoom: zoom, onFocus: focusChanged
                )
                .id(frozen?.ownKey ?? ownKey)
                if !items.isEmpty {
                    Hairline()
                        .padding(.top, 12 * zoom)
                        .padding(.bottom, 8 * zoom)
                    VStack(alignment: .leading, spacing: 2 * zoom) {
                        ForEach(items) { item in
                            row(item, store: store)
                                .id(frozen?.keys[item.id] ?? item.key)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: Item, store: RecordStore) -> some View {
        NoteGroupRow(
            item: item, lectureID: lectureID, courseID: rows.lecture?.courseID, deck: rows.deck, store: store, services: services,
            zoom: zoom, onOpenSlide: onOpenSlide, onFocus: focusChanged
        )
        .padding(.vertical, 7 * zoom)
        .padding(.horizontal, 8)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
            rowFrames[item.id] = frame
        }
        .padding(.horizontal, -8)
    }

    // MARK: Rows

    /// One group: a slide's notes and ink, or (a lecture without a deck) one note at its moment.
    struct Item: Identifiable, Equatable {
        let id: String
        var page: Int?
        var time: Double?
        var notes: [Note]
        var ink: InkDrawing?
        /// The section it belongs to (§4.4).
        var section: String?

        /// Changes when the group is to be drawn again (a note added, edited or deleted elsewhere).
        var key: String {
            id + "|" + notes.map { "\($0.id)@\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: ",")
        }
    }

    /// The lecture's own notes: the notes without a slide (with a deck), or without a slide and a
    /// moment (without one: the timed notes list by time).
    private var ownNotes: [Note] {
        rows.notes.filter { $0.pageNumber == nil && (rows.deck != nil || $0.audioTime == nil) }
    }

    private var ownKey: String {
        "own|" + ownNotes.map { "\($0.id)@\($0.updatedAt.timeIntervalSinceReferenceDate)" }.joined(separator: ",")
    }

    private func items(sections: [LectureNotesSection]) -> [Item] {
        var byPage: [Int: [Note]] = [:]
        for note in rows.notes {
            if let page = note.pageNumber { byPage[page, default: []].append(note) }
        }
        var pages = Set(byPage.keys).union(rows.ink.keys)
        // A group whose note is being typed in stays (emptied, its note is deleted on save).
        if let frozen { pages.formUnion(frozen.pages) }
        var items = pages.sorted().map { page in
            Item(
                id: "p\(page)", page: page, notes: (byPage[page] ?? []).sorted { $0.createdAt < $1.createdAt }, ink: rows.ink[page],
                section: LectureNotesSection.holding(page: page, in: sections)?.key
            )
        }
        if rows.deck == nil {
            let timed = rows.notes.filter { $0.pageNumber == nil && $0.audioTime != nil }.sorted { ($0.audioTime ?? 0) < ($1.audioTime ?? 0) }
            items += timed.map { note in
                Item(
                    id: "t\(note.id)", time: note.audioTime, notes: [note],
                    section: note.audioTime.flatMap { LectureNotesSection.holding(time: $0, recording: note.recordingID, in: sections)?.key }
                )
            }
        }
        return items
    }

    // MARK: Marking and scrolling (§4.4)

    /// The one quiet fill under the groups followed: the section's, or the slide's.
    private func runRect(_ items: [Item], follow: YourNotesFollow) -> CGRect? {
        let followed: [Item]
        switch follow {
        case .section(let key?): followed = items.filter { $0.section == key }
        case .page(let page?): followed = items.filter { $0.page == page }
        case .section(nil), .page(nil): return nil
        }
        let frames = followed.compactMap { rowFrames[$0.id] }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// The marked groups a third down from the top, when they are not in view.
    private func scrollToRun(_ run: CGRect?) {
        guard let run, visible.height > 0 else { return }
        let isOpening = Date().timeIntervalSince(appearedAt) < 1
        if !isOpening { pendingScroll = false }
        guard !isHovering, focused.isEmpty, Date().timeIntervalSince(userScrolledAt) >= 2 else { return }
        guard run.minY < visible.minY || run.maxY > visible.maxY else { return }
        let y = max(0, run.minY - visible.height / 3)
        if reduceMotion || isOpening {
            position.scrollTo(y: y)
        } else {
            withAnimation(.smooth(duration: 0.3)) { position.scrollTo(y: y) }
        }
    }

    private static func isStudent(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }

    private func focusChanged(_ id: Note.ID, _ isFocused: Bool) {
        if isFocused { focused.insert(id) } else { focused.remove(id) }
    }
}

/// The lecture's own note(s), edited as in Notes. Empty: a 96 pt area on the quiet fill (radius
/// 9, no placeholder) whose click puts the caret in the note.
private struct OwnNoteView: View {
    let anchor: NoteAnchor
    let notes: [Note]
    let store: RecordStore
    let lectureID: Lecture.ID
    let zoom: CGFloat
    let onFocus: (Note.ID, Bool) -> Void
    /// Made once, when the view appears: never in `init`, which runs on every redraw of the column
    /// (each time a session per note, with its body decoded, thrown away by `State`).
    @State private var editor: SlideNoteEditor?
    @State private var focusRequest = 0

    var body: some View {
        let isBlank = !(editor?.hasNotes ?? false)
        VStack(alignment: .leading, spacing: 7 * zoom) {
            ForEach(editor?.sessions ?? []) { session in
                NoteEditor(
                    session: session, style: .inspector, startsWith: .body, lectureID: lectureID,
                    focusRequest: session.isBlank ? focusRequest : 0,
                    onFocusChange: { onFocus(session.id, $0) }
                )
            }
        }
        .padding(.vertical, 6 * zoom)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: isBlank ? 96 * zoom : nil, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isBlank ? AnyShapeStyle(QuietFill()) : AnyShapeStyle(.clear))
                .contentShape(Rectangle())
                .onTapGesture { focusRequest += 1 }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, -8)
        .onAppear {
            if editor == nil { editor = SlideNoteEditor(anchor: anchor, notes: notes, store: store, playhead: { nil }) }
        }
        .onDisappear {
            guard let editor else { return }
            Task { await editor.flush() }
        }
    }
}

/// One group of Your notes: the chip in its leading column, then the ink thumbnail and the notes.
private struct NoteGroupRow: View {
    let item: YourNotesColumn.Item
    let lectureID: Lecture.ID
    let courseID: Course.ID?
    let deck: Deck?
    let store: RecordStore
    let services: StudyServices?
    let zoom: CGFloat
    /// Review moves its own review to the slide; nil: Review opens there.
    let onOpenSlide: ((Int) -> Void)?
    let onFocus: (Note.ID, Bool) -> Void
    /// Made once, when the row appears (as `OwnNoteView`'s).
    @State private var editor: SlideNoteEditor?
    @Environment(\.openDestination) private var openDestination

    var body: some View {
        HStack(alignment: .top, spacing: 8 * zoom) {
            chip
                .frame(width: 34 * zoom, alignment: .leading)
                .padding(.top, zoom)
            VStack(alignment: .leading, spacing: 7 * zoom) {
                if let page = item.page, let ink = item.ink, let deck {
                    SlideFigureView(
                        deck: deck, page: page, maxWidth: 176 * zoom, showsChip: false, showsInk: true, ink: ink, zoom: zoom,
                        services: services, openSlide: { open() }
                    )
                    // Its width holds while a divider is dragged; the notes beside it reflow.
                    .defersReflowWhileResizing()
                    .accessibilityLabel(Text("Slide \(page) with your ink"))
                }
                ForEach(editor?.sessions ?? []) { session in
                    NoteEditor(
                        session: session, style: .inspector, startsWith: .body, lectureID: lectureID,
                        onFocusChange: { onFocus(session.id, $0) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard editor == nil else { return }
            let anchor = NoteAnchor(courseID: courseID, lectureID: lectureID, deckID: item.page == nil ? nil : deck?.id, page: item.page, recordingID: nil)
            editor = SlideNoteEditor(anchor: anchor, notes: item.notes, store: store, playhead: { nil })
        }
        .onDisappear {
            guard let editor else { return }
            Task { await editor.flush() }
        }
    }

    @ViewBuilder
    private var chip: some View {
        if let page = item.page {
            NotesChip(text: "S\(page)", size: 10.5 * zoom) { open() }
        } else if let time = item.time {
            NotesChip(text: TimeText.clock(time), kind: .moment, size: 10.5 * zoom) { open() }
        }
    }

    private func open() {
        if let page = item.page, let onOpenSlide {
            onOpenSlide(page)
        } else if let page = item.page {
            openDestination(.lecture(lectureID, ReviewTarget(page: page)))
        } else if let time = item.time {
            openDestination(.lecture(lectureID, ReviewTarget(time: time, plays: true, recordingID: item.notes.first?.recordingID)))
        }
    }
}

/// The pane's background: the system's in light mode, lifted a little in dark mode (as Review's
/// and Calendar's).
private struct ColumnBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            Rectangle().fill(.white.opacity(0.025)).ignoresSafeArea()
        }
    }
}

/// Esc ends typing in a note of the column (the note editor keeps Esc for its sketches): a local
/// key monitor while one of its notes has focus.
private struct EscapeEndsTyping: ViewModifier {
    let isActive: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                if active { install() } else { remove() }
            }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return event }
            let ended = MainActor.assumeIsolated { () -> Bool in
                guard let window = event.window, window.firstResponder is NSTextView else { return false }
                return window.makeFirstResponder(nil)
            }
            return ended ? nil : event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Data

/// What Your notes shows, in one observed read: the lecture's notes by (slide, creation) without
/// Edit as Note copies, its slides (range and deck) and the non-empty ink of the range's pages.
/// Not `lecture_notes` (the sections come from the page): a streaming version is written ten times
/// a second, and every write would run this read again.
struct YourNotesRows: Equatable, Sendable {
    var isLoaded = false
    var lecture: Lecture?
    var notes: [Note] = []
    var range: LectureSlideRange?
    var deck: Deck?
    /// The newest drawing per page, non-empty only.
    var ink: [Int: InkDrawing] = [:]

    static let empty = YourNotesRows()
}

struct YourNotesRequest: FetchKeyRequest {
    let lectureID: Lecture.ID

    func fetch(_ db: Database) throws -> YourNotesRows {
        let id = lectureID
        let reference = Lecture.ID?.some(id)
        var rows = YourNotesRows(isLoaded: true)
        rows.lecture = try Lecture.find(id).fetchOne(db)
        rows.notes = try Note.where { $0.lectureID.eq(reference) }.order { ($0.pageNumber, $0.createdAt) }.fetchAll(db)
            .filter { !$0.isLectureNotesCopy }
        rows.range = try LectureSlides.current(lectureID: id, in: db)
        if let range = rows.range {
            let deckID = range.deckID
            rows.deck = try Deck.find(deckID).fetchOne(db)
            let first = range.firstPage
            let last = range.lastPage
            // The range's pages only: a deck can span several lectures.
            let inks = try SlideInk
                .where { $0.deckID.eq(deckID) && $0.pageNumber.gte(first) && $0.pageNumber.lte(last) }
                .order { $0.updatedAt.desc() }
                .fetchAll(db)
            for row in inks where rows.ink[row.pageNumber] == nil && !row.drawing.isEmpty {
                rows.ink[row.pageNumber] = row.drawing
            }
        }
        return rows
    }
}
#endif
