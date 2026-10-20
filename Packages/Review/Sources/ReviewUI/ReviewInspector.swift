import Notes
import NotesUI
import Review
import StudyCore
import StudyUI
import SwiftUI

/// The inspector: "This slide | Whole lecture" and the hide button in one 52 pt header row level
/// with the window toolbar, a hairline, then the pane. This slide holds the slide's summary, your
/// notes for the slide on screen (editable, autosaved) and its further reading, then, under a
/// hairline, the lecture-wide exam hints and things only said in class (3 rows each, then "Show N
/// more"); Whole lecture holds the lecture's summary, every exam hint, everything only said in
/// class by category, every further reading and every note of the lecture by slide (M4).
///
/// In the window the header is a toolbar item: macOS 26 lays the toolbar out as one row whose
/// trailing items pack against the window's edge, with no section of its own over the inspector.
/// The item is as wide as the inspector (less the toolbar's trailing inset), so it sits exactly
/// over the column and keeps the slide stepper beside it, over the content. It is there only while
/// the inspector is shown; then the toolbar's Show Inspector takes its place. ma: while the agent
/// panel is expanded it takes the inspector's place (`isShown` false).
struct ReviewInspector: View {
    static let width: CGFloat = 336
    static let headerHeight: CGFloat = 52
    /// The toolbar's inset from the window's trailing edge.
    static let toolbarTrailingInset: CGFloat = 11

    let model: ReviewModel
    /// The inspector is on screen (shown, and the agent panel not expanded in its place).
    var isShown = true

    @Environment(\.reviewChrome) private var chrome
    @State private var columnWidth = ReviewInspector.width
    /// The notes list's visible height: an empty slide's pane fills it, so a click anywhere under
    /// "Your notes" starts the note.
    @State private var listHeight: CGFloat = 0
    private let notesQuery: FetchAll<Note>
    private var notes: [Note] { notesQuery.wrappedValue }
    private let annotationsQuery: FetchAll<Annotation>

    init(model: ReviewModel, isShown: Bool = true) {
        self.model = model
        self.isShown = isShown
        let lectureID = model.lecture.id
        notesQuery = FetchAll(
            Note.where { $0.lectureID.eq(lectureID) }.order { ($0.pageNumber, $0.createdAt) },
            database: model.services.database
        )
        annotationsQuery = .studyItems(of: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chrome == .snapshot {
                InspectorHeader(model: model)
                    .padding(.trailing, Self.toolbarTrailingInset)
                    .frame(height: Self.headerHeight)
            }
            Divider()
            ScrollView {
                let items = StudyItems(annotationsQuery.wrappedValue)
                if model.deck == nil {
                    LectureOnlyNotesPane(model: model, notes: notes, items: items)
                } else {
                    switch model.inspectorTab {
                    case .slide:
                        SlideNotesPane(model: model, notes: notes, items: items, minHeight: listHeight)
                    case .lecture:
                        LectureNotesPane(model: model, notes: notes, items: items)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { InspectorBackground() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .toolbar {
            // Only while the inspector is shown: SwiftUI keeps a hidden inspector's content (and
            // with it this item) alive, so the header stayed in the toolbar beside Show Inspector.
            if chrome == .window, model.showsInspector, isShown {
                ToolbarItem(placement: .automatic) {
                    InspectorHeader(model: model)
                        .frame(width: max(0, columnWidth - Self.toolbarTrailingInset))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }
}

/// The inspector column's background: the system's as is in light mode; in dark mode lifted a
/// little above the content (which it otherwise matches) so it reads as a panel of its own.
/// Snapshots have no inspector column, so they draw the secondary background.
private struct InspectorBackground: View {
    @Environment(\.reviewChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch chrome {
        case .window:
            if colorScheme == .dark {
                Rectangle().fill(.white.opacity(0.025)).ignoresSafeArea()
            }
        case .snapshot:
            Rectangle().fill(.background.secondary)
        }
    }
}

/// The header row: the tab picker (its own track, mockup 03's one segctl), then the hide button at
/// the trailing edge.
private struct InspectorHeader: View {
    let model: ReviewModel

    var body: some View {
        HStack(spacing: 8) {
            if model.deck != nil {
                InspectorTabPicker(model: model)
            }
            Spacer(minLength: 0)
            Button {
                model.showsInspector = false
            } label: {
                Label("Hide Inspector", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("Hide Inspector"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
    }
}

/// "This slide | Whole lecture": a small segmented control (on a toolbar glass track its selection
/// is neutral, not accent-filled); only with a deck.
private struct InspectorTabPicker: View {
    let model: ReviewModel

    var body: some View {
        let selection = Binding<ReviewModel.InspectorTab> {
            model.inspectorTab
        } set: { tab in
            model.inspectorTab = tab
        }
        Picker("Notes", selection: selection) {
            Text("This slide").tag(ReviewModel.InspectorTab.slide)
            Text("Whole lecture").tag(ReviewModel.InspectorTab.lecture)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }
}

/// "Your notes" for the slide on screen. A new editor per slide; leaving the slide saves.
///
/// While a note is being typed the pane stays on the slide the typing started on: playback with
/// Follow moving to the next slide must not take the editor (and its focus) away mid-word. It
/// catches up with the slide on screen once the editor lets go of focus.
private struct SlideNotesPane: View {
    let model: ReviewModel
    let notes: [Note]
    /// The study pass's rows (M4): the slide's summary and further reading, then the lecture-wide
    /// exam hints and things only said in class.
    let items: StudyItems
    /// The list's visible height, which the pane fills.
    var minHeight: CGFloat = 0
    /// The slide whose notes are being typed (nil: follow the slide on screen).
    @State private var typingOn: TypingPage?
    /// A click in the pane's empty room: the empty note takes the caret (no placeholder copy).
    @State private var focusRequest = 0

    private struct TypingPage: Equatable {
        var page: Int?
    }

    var body: some View {
        let page = typingOn.map(\.page) ?? model.session.shownPage
        VStack(alignment: .leading, spacing: 14) {
            if let page, let summary = items.slideSummaries[page] {
                SummaryBlock(model: model, summary: summary)
            }
            VStack(alignment: .leading, spacing: 7) {
                SectionLabel("Your notes")
                SlideNoteEditorView(model: model, page: page, notes: notes.filter { $0.pageNumber == page }, focusRequest: focusRequest)
                    .id(page)
            }
            if let page {
                let readings = items.furtherReading(page: page)
                if !readings.isEmpty {
                    FurtherReadingBlock(model: model, readings: Array(readings.prefix(2)))
                }
            }
            // Lecture-wide (mockup 03): the admission rules at 0:37 never hide behind slide 16.
            if items.hasLectureWideItems {
                Hairline()
                if !items.examHints.isEmpty {
                    ExamHintsBlock(model: model, hints: items.examHints, limit: 3)
                }
                if !items.saidInClass.isEmpty {
                    SaidInClassBlock(model: model, items: items.saidInClass, limit: 3)
                }
            }
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { focusRequest += 1 }
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .onChange(of: model.isEditingText) { _, editing in
            typingOn = editing ? TypingPage(page: typingOn.map(\.page) ?? model.session.shownPage) : nil
        }
    }
}

/// The notes of one slide (or, `page` nil, of the lecture itself), each a rich `NoteEditor` in the
/// inspector style; a slide without notes has one empty editor that becomes a note on its first
/// keystroke. Leaving the slide saves.
private struct SlideNoteEditorView: View {
    let model: ReviewModel
    /// Bumped to put the caret in the empty note.
    var focusRequest = 0
    @State private var editor: SlideNoteEditor

    init(model: ReviewModel, page: Int?, notes: [Note], focusRequest: Int = 0) {
        self.model = model
        self.focusRequest = focusRequest
        let player = model.player
        _editor = State(initialValue: SlideNoteEditor(
            anchor: NoteAnchor(
                courseID: model.lecture.courseID, lectureID: model.lecture.id, deckID: model.deckID,
                page: page, recordingID: model.recording?.id
            ),
            notes: notes,
            store: model.services.records,
            playhead: { player?.time }
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(editor.sessions) { session in
                NoteSessionRow(model: model, session: session, focusRequest: focusRequest)
            }
        }
        .onDisappear {
            let editor = editor
            Task { await editor.flush() }
        }
    }
}

/// One note: your pin and the note (mockup 03's `.mynote`), its time chip after the last word
/// when it is anchored to the recording. Typing in it sets `isEditingText` (the review's plain
/// keys detach and the pane keeps its slide).
private struct NoteSessionRow: View {
    let model: ReviewModel
    let session: NoteSession
    /// Bumped by a click in the pane's empty room: an empty note takes the caret.
    var focusRequest = 0

    private var isBlank: Bool {
        session.note?.isBlank ?? true
    }

    var body: some View {
        let model = model
        HStack(alignment: .top, spacing: 7) {
            // The pin marks your text: none beside an empty note, but its place is kept so typing
            // does not shift the line.
            ProvenancePin(.user)
                .padding(.top, 1)
                .opacity(isBlank ? 0 : 1)
            NoteEditor(
                session: session,
                style: .inspector,
                startsWith: .body,
                professor: model.professorSurname.isEmpty ? nil : String(localized: "Prof. \(model.professorSurname)"),
                lectureID: model.lecture.id,
                trailingTime: model.player == nil ? nil : session.note?.audioTime,
                focusRequest: isBlank ? focusRequest : 0,
                onFocusChange: { model.isEditingText = $0 },
                onLink: { ReviewNoteLinks.open($0, model: model) }
            )
        }
    }
}

/// A chip in a note of this lecture moves the review (the slide, or playback from the moment);
/// one of another lecture opens that lecture.
@MainActor
enum ReviewNoteLinks {
    static func open(_ link: NoteLink, model: ReviewModel) -> Bool {
        switch link {
        case .slide(let source):
            guard (source.lectureID ?? model.lecture.id) == model.lecture.id, let page = source.pageNumber,
                  source.deckID == nil || source.deckID == model.deckID, model.deck != nil, model.shows(page: page)
            else { return false }
            Task { await model.session.selectThumbnail(page: page) }
            return true
        case .time(let source):
            guard (source.lectureID ?? model.lecture.id) == model.lecture.id, let time = source.time, model.player != nil,
                  source.recordingID == nil || source.recordingID == model.recording?.id
            else { return false }
            Task { await model.session.play(from: time) }
            return true
        }
    }
}

/// "Your notes" on Whole lecture (and without a deck): the lecture's own notes (editable), then the
/// notes of its slides, read-only, each after its `SlideChip`.
private struct LectureYourNotes: View {
    let model: ReviewModel
    let notes: [Note]

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Your notes")
            SlideNoteEditorView(model: model, page: nil, notes: notes.filter { $0.pageNumber == nil })
            ForEach(notes.filter { $0.pageNumber != nil && !$0.isBlank }) { note in
                HStack(alignment: .top, spacing: 7) {
                    if let page = note.pageNumber {
                        SlideChip(page: page) {
                            Task { await model.session.selectThumbnail(page: page) }
                        }
                        .padding(.top, 1)
                    }
                    NoteEditor(
                        note: note, style: .inspector,
                        professor: model.professorSurname.isEmpty ? nil : String(localized: "Prof. \(model.professorSurname)"),
                        onLink: { ReviewNoteLinks.open($0, model: model) }
                    )
                    // Drawn again when the note changes (it is edited on This slide).
                    .id("\(note.id)-\(note.updatedAt.timeIntervalSinceReferenceDate)")
                }
            }
        }
    }
}

/// Without a deck: notes on the lecture itself (editable), then any slide notes it kept.
private struct LectureOnlyNotesPane: View {
    let model: ReviewModel
    let notes: [Note]
    let items: StudyItems

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = items.lectureSummary {
                SummaryBlock(model: model, summary: summary)
            }
            LectureYourNotes(model: model, notes: notes)
            if items.hasLectureWideItems {
                Hairline()
                if !items.examHints.isEmpty {
                    ExamHintsBlock(model: model, hints: items.examHints)
                }
                if !items.saidInClass.isEmpty {
                    SaidInClassBlock(model: model, items: items.saidInClass, groups: items.saidInClassByCategory)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole lecture: summary, exam hints, things said in class, further reading, then your notes.
private struct LectureNotesPane: View {
    let model: ReviewModel
    let notes: [Note]
    /// The study pass's rows (M4): the lecture's summary, every exam hint, everything only said in
    /// class by category, every further reading.
    let items: StudyItems

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = items.lectureSummary {
                SummaryBlock(model: model, summary: summary)
            }
            if !items.examHints.isEmpty {
                ExamHintsBlock(model: model, hints: items.examHints)
            }
            if !items.saidInClass.isEmpty {
                SaidInClassBlock(model: model, items: items.saidInClass, groups: items.saidInClassByCategory)
            }
            if !items.furtherReading.isEmpty {
                FurtherReadingBlock(model: model, readings: items.furtherReading, showsSlides: true)
            }
            LectureYourNotes(model: model, notes: notes)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
