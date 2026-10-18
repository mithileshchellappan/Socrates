import ChatUI
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
/// the inspector is shown; then the toolbar's Show Inspector takes its place.
struct ReviewInspector: View {
    static let width: CGFloat = 336
    static let headerHeight: CGFloat = 52
    /// The toolbar's inset from the window's trailing edge.
    static let toolbarTrailingInset: CGFloat = 11

    let model: ReviewModel

    @Environment(\.reviewChrome) private var chrome
    @Environment(\.chatActions) private var chatActions
    @State private var columnWidth = ReviewInspector.width
    /// The notes list's visible height: an empty slide's pane fills it, so a click anywhere under
    /// "Your notes" starts the note.
    @State private var listHeight: CGFloat = 0
    private let notesQuery: FetchAll<Note>
    private var notes: [Note] { notesQuery.wrappedValue }
    private let annotationsQuery: FetchAll<Annotation>

    init(model: ReviewModel) {
        self.model = model
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
            if model.inspectorTab == .tutor, chatActions.isAvailable {
                // M5: the tutor about this lecture; its own scroll view and composer.
                TutorPane(model: model)
            } else {
                ScrollView {
                    let items = StudyItems(annotationsQuery.wrappedValue)
                    if model.deck == nil {
                        LectureOnlyNotesPane(model: model, notes: notes, items: items)
                    } else {
                        switch model.inspectorTab {
                        case .slide, .tutor:
                            SlideNotesPane(model: model, notes: notes, items: items, minHeight: listHeight)
                        case .lecture:
                            LectureNotesPane(model: model, notes: notes, items: items)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { InspectorBackground() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .toolbar {
            // Only while the inspector is shown: SwiftUI keeps a hidden inspector's content (and
            // with it this item) alive, so the header stayed in the toolbar beside Show Inspector.
            if chrome == .window, model.showsInspector {
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

/// The header row: the tab picker (its own track, mockup 03's one segctl), then (Tutor tab) the
/// chat's ⋯ with New Chat and Memory…, then the hide button at the trailing edge.
private struct InspectorHeader: View {
    let model: ReviewModel
    @Environment(\.chatActions) private var chatActions

    var body: some View {
        HStack(spacing: 8) {
            if model.deck != nil || chatActions.isAvailable {
                InspectorTabPicker(model: model, showsTutor: chatActions.isAvailable)
            }
            Spacer(minLength: 0)
            if chatActions.isAvailable, model.inspectorTab == .tutor {
                ChatMoreMenu(newChat: { model.newChatRequests += 1 })
            }
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

/// "This slide | Whole lecture | Tutor": a small segmented control (on a toolbar glass track its
/// selection is neutral, not accent-filled). Without a deck "This slide" is left out; without
/// Claude Code "Tutor" is.
private struct InspectorTabPicker: View {
    let model: ReviewModel
    let showsTutor: Bool

    var body: some View {
        let hasDeck = model.deck != nil
        let selection = Binding<ReviewModel.InspectorTab> {
            switch model.inspectorTab {
            case .tutor where !showsTutor: hasDeck ? .slide : .lecture
            case .slide where !hasDeck: .lecture
            case let tab: tab
            }
        } set: { tab in
            model.inspectorTab = tab
        }
        Picker("Notes", selection: selection) {
            if hasDeck {
                Text("This slide").tag(ReviewModel.InspectorTab.slide)
            }
            Text("Whole lecture").tag(ReviewModel.InspectorTab.lecture)
            if showsTutor {
                Text("Tutor").tag(ReviewModel.InspectorTab.tutor)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .fixedSize()
    }
}

/// M5: the Tutor tab: the chat about this lecture (`ChatPanel`), the newest tutor conversation of
/// the lecture. A message carries the slide on screen and the playhead (on the lecture's first
/// recording) as it is at ↩, read then, so the panel does not redraw with the playhead. While the
/// composer has focus the review's plain keys are off.
private struct TutorPane: View {
    let model: ReviewModel

    var body: some View {
        let model = model
        let lectureID = model.lecture.id
        ChatPanel(
            context: .lecture(lectureID, page: nil, time: nil),
            sendContext: {
                let onFirst = model.recording == nil || model.recording?.id == model.recordings.first?.id
                return .lecture(lectureID, page: model.session.shownPage, time: onFirst ? model.player?.time : nil)
            },
            newChat: model.newChatRequests,
            composerFocused: Binding(get: { model.isComposingChat }, set: { model.isComposingChat = $0 })
        )
        .onDisappear { model.isComposingChat = false }
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
            ForEach(editor.drafts) { draft in
                NoteDraftRow(model: model, editor: editor, draft: draft, focusRequest: focusRequest)
            }
        }
        .onDisappear {
            let editor = editor
            Task { await editor.flush() }
        }
    }
}

/// One note: your pin, the text, and a time chip when it is anchored to the recording. At rest
/// the note reads as prose (mockup 03's `.mynote`): checklist lines with their box and the chip at
/// the end of the last line. Clicking it edits the text (`- [ ] ` lines) with the chip below.
private struct NoteDraftRow: View {
    let model: ReviewModel
    let editor: SlideNoteEditor
    let draft: NoteDraft
    /// Bumped by a click in the pane's empty room: an empty note takes the caret.
    var focusRequest = 0

    @FocusState private var isFocused: Bool

    /// Lines the editor's text up with the pin (the text view's line fragment padding).
    #if os(macOS)
    private static let insetCorrection: CGFloat = -5
    #else
    private static let insetCorrection: CGFloat = -4
    #endif

    /// Shown read-only until it is clicked; an empty note is the editor (one quiet line).
    private var isAtRest: Bool {
        draft.isEditable && !isFocused && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            // The pin marks your text: none beside an empty note, but its place is kept so typing
            // does not shift the line.
            ProvenancePin(.user)
                .padding(.top, 1)
                .opacity(draft.text.isEmpty ? 0 : 1)
            VStack(alignment: .leading, spacing: 5) {
                if draft.isEditable {
                    // One structure at rest and while editing, so the editor (and its focus)
                    // survives the swap: the hidden view sizes it (a text view does not size
                    // itself), the prose covers it at rest.
                    Group {
                        if isAtRest {
                            NoteAtRest(blocks: NoteText.blocks(from: draft.text), time: chipTime, play: play)
                        } else {
                            Text(verbatim: draft.text.isEmpty ? " " : draft.text)
                                .font(.callout)
                                .lineSpacing(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .overlay {
                        TextEditor(text: Binding(
                            get: { draft.text },
                            set: { editor.setText($0, for: draft.id) }
                        ))
                        .font(.callout)
                        .lineSpacing(2)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .padding(.horizontal, Self.insetCorrection)
                        .focused($isFocused)
                        .opacity(isAtRest ? 0 : 1)
                        .allowsHitTesting(!isAtRest)
                        .accessibilityLabel(Text("Your notes"))
                    }
                    .overlay(alignment: .topLeading) {
                        if isAtRest {
                            NoteAtRest(blocks: NoteText.blocks(from: draft.text), time: chipTime, play: play)
                        }
                    }
                    if !isAtRest, let time = chipTime {
                        TimeChip(time, action: { play(time) })
                    }
                } else {
                    NoteAtRest(blocks: draft.note?.blocks ?? [], time: chipTime, play: play)
                }
            }
        }
        // The whole row takes a click into the note (an empty one is a single quiet line).
        .contentShape(Rectangle())
        .onTapGesture {
            if draft.isEditable { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            model.isEditingText = focused
        }
        .onChange(of: focusRequest) {
            if draft.isEditable, draft.text.isEmpty { isFocused = true }
        }
        .onDisappear {
            // Paging away while typing removes the editor without a focus change.
            if isFocused { model.isEditingText = false }
        }
    }

    private var chipTime: Double? {
        model.player == nil ? nil : draft.audioTime
    }

    private func play(_ time: Double) {
        Task { await model.session.play(from: time) }
    }
}

/// A note as prose: its lines (checklist items with their box), and the time chip after the last
/// word, on the last line when it fits, else on the next.
private struct NoteAtRest: View {
    let blocks: [NoteBlock]
    let time: Double?
    let play: (Double) -> Void

    var body: some View {
        if let time {
            NoteFlowLayout {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    if index > 0 {
                        Color.clear.frame(width: 0, height: 0).layoutValue(key: NoteFlowLayout.LineBreak.self, value: true)
                    }
                    if block.type == .checklist {
                        Text(Image(systemName: block.checked == true ? "checkmark.square" : "square"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(block.text.split(separator: " ").enumerated()), id: \.offset) { _, word in
                        Text(verbatim: String(word))
                    }
                }
                TimeChip(time) { play(time) }
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        } else {
            NoteBody(blocks: blocks)
        }
    }
}

/// Words left to right, wrapping at the proposed width; a `LineBreak` view starts a new line.
/// Each line is centred on its tallest item (the chip), lines `lineSpacing` apart.
struct NoteFlowLayout: Layout {
    /// The note text's line pitch (callout with 2 pt line spacing) and a space's width.
    var lineSpacing: CGFloat = 2
    var wordSpacing: CGFloat = 3.3

    struct LineBreak: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var line: [(index: Int, size: CGSize, x: CGFloat)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0
        func closeLine() {
            let height = line.map(\.size.height).max() ?? 0
            for item in line {
                frames[item.index] = CGRect(x: item.x, y: y + (height - item.size.height) / 2, width: item.size.width, height: item.size.height)
            }
            if !line.isEmpty { y += height + lineSpacing }
            line = []
            x = 0
        }
        for (index, subview) in subviews.enumerated() {
            if subview[LineBreak.self] {
                closeLine()
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { closeLine() }
            line.append((index, size, x))
            x += size.width + wordSpacing
            widest = max(widest, x - wordSpacing)
        }
        closeLine()
        return (frames, CGSize(width: min(widest, width), height: max(0, y - lineSpacing)))
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
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Your notes")
                SlideNoteEditorView(model: model, page: nil, notes: notes.filter { $0.pageNumber == nil })
                ForEach(notes.filter { $0.pageNumber != nil && !$0.isBlank }) { note in
                    NoteBody(blocks: note.blocks)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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

/// Every note of the lecture, by slide.
private struct LectureNotesPane: View {
    let model: ReviewModel
    let notes: [Note]
    /// The study pass's rows (M4): the lecture's summary, every exam hint, everything only said in
    /// class by category, every further reading.
    let items: StudyItems

    var body: some View {
        let visible = notes.filter { !$0.isBlank }
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
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Your notes")
                ForEach(visible) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let page = note.pageNumber {
                            SlideChip(page: page) {
                                Task { await model.session.selectThumbnail(page: page) }
                            }
                        }
                        NoteBody(blocks: note.blocks)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A note shown read-only: one line per block, checklist items with their box.
private struct NoteBody: View {
    let blocks: [NoteBlock]

    var body: some View {
        blocks.enumerated().reduce(Text(verbatim: "")) { text, item in
            let (index, block) = item
            let separator = index == 0 ? "" : "\n"
            guard block.type == .checklist else { return Text("\(text)\(separator)\(block.text)") }
            let box = Text(Image(systemName: block.checked == true ? "checkmark.square" : "square")).foregroundStyle(.secondary)
            return Text("\(text)\(separator)\(box) \(block.text)")
        }
        .font(.callout)
        .lineSpacing(2)
        .textSelection(.enabled)
    }
}
