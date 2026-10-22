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
/// - In Review a note started here gets the recording on screen and the playhead then (DESIGN 8.1);
///   the lecture's own note shows its moment after its last word, and without a deck a note with a
///   moment lists by it once the typing ends (it stays where it is typed until then).
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
/// `body` does no work: the groups are prepared when their inputs change (`YourNotesGroups`), and
/// a scroll frame writes only a box `body` never reads (the slide moving while the student scrolls
/// redraws no group).
public struct YourNotesColumn: View {
    private nonisolated static let space = "yourNotes"

    private let lectureID: Lecture.ID
    private let sections: @MainActor () -> [LectureNotesSection]
    private let follow: @MainActor () -> YourNotesFollow
    private let recordingID: Recording.ID?
    private let playhead: @MainActor () -> Double?
    private let onOpenSlide: ((Int) -> Void)?
    private let onLink: ((NoteLink) -> Bool)?
    private let onEditingChange: (Bool) -> Void

    @Fetch private var rows: YourNotesRows
    @Environment(\.studyServices) private var services
    @Environment(\.contentZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the column lists, prepared when the rows, the sections or the typing change.
    @State private var groups = YourNotesGroups()
    /// The notes being typed in (their sessions).
    @State private var focused: Set<Note.ID> = []
    /// While a note is being typed in, its group stays and nothing is drawn again under it.
    @State private var frozen: Frozen?
    /// The one quiet fill under the groups followed, placed again only when one of them moves.
    @State private var run: CGRect?
    /// The visible part and the groups' frames: written on every scroll and layout frame, never
    /// read in `body`, so scrolling draws nothing again.
    @State private var measured = Measured()
    @State private var position = ScrollPosition(edge: .top)
    @State private var isHovering = false
    @State private var userScrolledAt = Date.distantPast
    /// What it follows is to be scrolled into view: from the start (it opens there) and after each
    /// change of what it follows, until one placement was decided.
    @State private var pendingScroll = true
    /// While its rows load and grow (editors made as they appear), the opening placement is taken
    /// again as the groups move, at once.
    @State private var appearedAt = Date()
    /// The notes typed in the lecture's own note since the typing started. Without a deck one with
    /// a moment lists by time, but not before the typing ends (it would show twice).
    @State private var typedInOwn: Set<Note.ID> = []
    /// Bumped when the typing in the own note ends without a deck: it is drawn again without the
    /// notes that now list by their moment.
    @State private var ownGeneration = 0

    /// - Parameters:
    ///   - sections: the current version's sections (the notes page reads them; this column's read
    ///     leaves `lecture_notes` alone, which is written ten times a second while notes stream).
    ///   - follow: what the column marks and scrolls to.
    ///   - recordingID: the recording on screen (Review), which a new note is anchored to.
    ///   - playhead: the player's time when a new note is started (Review); nil: no moment.
    ///   - onOpenSlide: a slide's chip or thumbnail (Review moves its own review); nil: Review opens
    ///     at the slide.
    ///   - onLink: a chip inside a note (Review moves its own review); nil, or false: it navigates.
    ///   - onEditingChange: a note in the column has focus or no longer has (the page's ↩ and the
    ///     review's keys stand down meanwhile).
    public init(
        lectureID: Lecture.ID,
        sections: @escaping @MainActor () -> [LectureNotesSection] = { [] },
        follow: @escaping @MainActor () -> YourNotesFollow,
        recordingID: Recording.ID? = nil,
        playhead: @escaping @MainActor () -> Double? = { nil },
        onOpenSlide: ((Int) -> Void)? = nil,
        onLink: ((NoteLink) -> Bool)? = nil,
        onEditingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.lectureID = lectureID
        self.sections = sections
        self.follow = follow
        self.recordingID = recordingID
        self.playhead = playhead
        self.onOpenSlide = onOpenSlide
        self.onLink = onLink
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
        let source = YourNotesGroups.Source(
            rows: rows, sections: sections(), keptPages: frozen?.pages ?? [], typedInOwn: typedInOwn, ownGeneration: ownGeneration
        )
        ScrollView {
            content
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
        .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in
            let resized = rect.height != measured.visible.height
            measured.visible = rect
            if resized, pendingScroll { scrollToRun(run) }
        }
        .onScrollPhaseChange { old, new in
            if Self.isStudent(old) || Self.isStudent(new) { userScrolledAt = Date() }
        }
        .onHover { isHovering = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ColumnBackground() }
        .modifier(EscapeEndsTyping(isActive: !focused.isEmpty))
        .onChange(of: source, initial: true) { _, source in
            let groups = YourNotesGroups(source)
            self.groups = groups
            placeRun(groups: groups, follow: self.follow())
        }
        .onChange(of: focused.isEmpty) { _, idle in
            frozen = idle ? nil : Frozen(
                keys: Dictionary(uniqueKeysWithValues: groups.items.map { ($0.id, $0.key) }),
                pages: Set(groups.items.compactMap(\.page)),
                ownKey: groups.ownKey
            )
            if idle {
                if rows.deck == nil, !typedInOwn.isEmpty { ownGeneration += 1 }
                typedInOwn = []
            }
            onEditingChange(!idle)
        }
        .onChange(of: follow) { _, follow in
            pendingScroll = true
            scrollToRun(placeRun(groups: groups, follow: follow))
        }
        .onChange(of: run) { _, run in
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
    private var content: some View {
        if groups.isLoaded, let store = services?.records {
            VStack(alignment: .leading, spacing: 0) {
                OwnNoteView(
                    anchor: NoteAnchor(courseID: rows.lecture?.courseID, lectureID: lectureID, deckID: nil, page: nil, recordingID: recordingID),
                    notes: groups.ownNotes, store: store, lectureID: lectureID, zoom: zoom, playhead: playhead, showsMoments: recordingID != nil,
                    onLink: onLink, onFocus: ownFocusChanged
                )
                .id(frozen?.ownKey ?? groups.ownKey)
                if !groups.items.isEmpty {
                    Hairline()
                        .padding(.top, 12 * zoom)
                        .padding(.bottom, 8 * zoom)
                    VStack(alignment: .leading, spacing: 2 * zoom) {
                        ForEach(groups.items) { item in
                            row(item, store: store)
                                .id(frozen?.keys[item.id] ?? item.key)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: YourNotesGroups.Item, store: RecordStore) -> some View {
        NoteGroupRow(
            item: item, lectureID: lectureID, courseID: rows.lecture?.courseID, deck: rows.deck, store: store, services: services,
            zoom: zoom, recordingID: recordingID, playhead: playhead, onOpenSlide: onOpenSlide, onLink: onLink, onFocus: focusChanged
        )
        .padding(.vertical, 7 * zoom)
        .padding(.horizontal, 8)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
            measured.rowFrames[item.id] = frame
            // Only a followed group moving moves the fill.
            let follow = follow()
            if item.isFollowed(by: follow) { placeRun(groups: groups, follow: follow) }
        }
        .padding(.horizontal, -8)
    }

    // MARK: Marking and scrolling (§4.4)

    /// Places the quiet fill under the groups `follow` marks (written only when it moves) and
    /// returns where it is.
    @discardableResult
    private func placeRun(groups: YourNotesGroups, follow: YourNotesFollow) -> CGRect? {
        let rect = groups.run(following: follow, frames: measured.rowFrames)
        if rect != run { run = rect }
        return rect
    }

    /// The marked groups a third down from the top, when they are not in view.
    private func scrollToRun(_ run: CGRect?) {
        let visible = measured.visible
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

    private func ownFocusChanged(_ id: Note.ID, _ isFocused: Bool) {
        if isFocused { typedInOwn.insert(id) }
        focusChanged(id, isFocused)
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
    let playhead: @MainActor () -> Double?
    /// A note's moment shows after its last word (Review).
    let showsMoments: Bool
    let onLink: ((NoteLink) -> Bool)?
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
                    trailingTime: showsMoments ? session.note?.audioTime : nil,
                    focusRequest: session.isBlank ? focusRequest : 0,
                    onFocusChange: { onFocus(session.id, $0) },
                    onLink: onLink
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
            if editor == nil { editor = SlideNoteEditor(anchor: anchor, notes: notes, store: store, playhead: playhead) }
        }
        .onDisappear {
            guard let editor else { return }
            Task { await editor.flush() }
        }
    }
}

/// One group of Your notes: the chip in its leading column, then the ink thumbnail and the notes.
private struct NoteGroupRow: View {
    let item: YourNotesGroups.Item
    let lectureID: Lecture.ID
    let courseID: Course.ID?
    let deck: Deck?
    let store: RecordStore
    let services: StudyServices?
    let zoom: CGFloat
    /// The recording a new note of the slide is anchored to, and the playhead then (Review).
    let recordingID: Recording.ID?
    let playhead: @MainActor () -> Double?
    /// Review moves its own review to the slide; nil: Review opens there.
    let onOpenSlide: ((Int) -> Void)?
    let onLink: ((NoteLink) -> Bool)?
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
                    // No moment after the last word: the group's chip says where it belongs (mockups
                    // 34–35, 40), and a note listed by its moment has it as its chip.
                    NoteEditor(
                        session: session, style: .inspector, startsWith: .body, lectureID: lectureID,
                        onFocusChange: { onFocus(session.id, $0) },
                        onLink: onLink
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard editor == nil else { return }
            let anchor = NoteAnchor(
                courseID: courseID, lectureID: lectureID, deckID: item.page == nil ? nil : deck?.id, page: item.page, recordingID: recordingID
            )
            editor = SlideNoteEditor(anchor: anchor, notes: item.notes, store: store, playhead: playhead)
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

/// Where Your notes' groups are laid out and which part of them is in view. A reference the
/// column keeps in `@State` and never reads in `body`: writing it on every scroll or layout frame
/// draws nothing again (as StudyUI's held widths).
@MainActor
private final class Measured {
    var visible: CGRect = .zero
    var rowFrames: [String: CGRect] = [:]
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
