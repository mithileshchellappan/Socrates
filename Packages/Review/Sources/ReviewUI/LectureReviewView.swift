import Capture
import Review
import StudyCore
import StudyUI
import SwiftUI

/// The lecture review screen (PRD #14, mockup 03): the slide on screen, a rail of thumbnails, the
/// transcript grouped by slide visit, a floating player on one recording clock, and the notes:
/// This slide (#15), Whole lecture (the student's own notes) and Summary (Claude's notes of the
/// lecture). On the Mac the notes are the screen's side pane (`.pane(.notes, …)`), on the iPad its
/// inspector. Clicking a line plays from it; "Slide N Starts Here" sets a manual anchor and
/// re-aligns at once through `realign` (#9).
///
/// The app passes `Realigner(services:).realign` and installs `\.studyServices`, SQLiteData's
/// default database and `ReviewCommands` (Space, ⌥←/⌥→, ←/→, ⇧⌘F, ⌘\, ⇧⌘R; M6 on the Mac: P, H, E,
/// F, Esc; View ⌃⌥⌘1, ⌃⌥⌘2). On the Mac ← / → and Page Up / Page Down page the slides through the
/// screen's own key monitor (`ReviewSlideKeys`) whenever no text in the window has the keyboard
/// and no pane is maximized over the screen.
///
/// - Without a deck there is no rail and no slide; without a recording no player and no
///   transcript; before the transcript exists the transcript zone shows the job's progress.
/// - Opens at `target` (page and/or time, optionally playing), else where review left off.
/// - The notes tab is kept per window (`review.notesTab`); renders pick theirs
///   (`\.reviewInspectorTab`).
/// - nl: its content zooms (`.contentZoomable()`): the transcript and the notes' text.
public struct LectureReviewView: View {
    private let lectureID: Lecture.ID
    private let target: ReviewTarget
    private let realign: @Sendable (Lecture.ID, Recording.ID) async throws -> Void

    @Environment(\.studyServices) private var services
    /// Renders' tab: it wins over the window's.
    @Environment(\.reviewInspectorTab) private var renderTab
    /// The notes tab this window shows (`ReviewInspectorTab.rawValue`), for every review it opens.
    @SceneStorage("review.notesTab") private var storedTab = ReviewInspectorTab.slide.rawValue
    private let recordingsQuery: FetchAll<Recording>
    private var recordings: [Recording] { recordingsQuery.wrappedValue }
    private let deckLinksQuery: FetchAll<LectureDeckSpan>
    private var deckLinks: [LectureDeckSpan] { deckLinksQuery.wrappedValue }
    @State private var model: ReviewModel?
    /// The target the screen has moved to already: it is applied once, not again on a reload.
    @State private var appliedTarget: ReviewTarget?
    /// The recording picked in the toolbar (a lecture with more than one).
    @State private var chosenRecording: Recording.ID?
    /// A moment on another recording asked for from inside the screen (`requestedMoment`): the
    /// next load opens there.
    @State private var movedTo: ReviewTarget?

    public init(
        lectureID: Lecture.ID,
        target: ReviewTarget = ReviewTarget(),
        realign: @escaping @Sendable (Lecture.ID, Recording.ID) async throws -> Void
    ) {
        self.lectureID = lectureID
        self.target = target
        self.realign = realign
        recordingsQuery = FetchAll(Recording.where { $0.lectureID.eq(lectureID) }.order(by: \.startedAt))
        deckLinksQuery = FetchAll(LectureDeckSpan.where { $0.lectureID.eq(lectureID) && $0.startTime.is(nil) }.order(by: \.updatedAt))
    }

    public var body: some View {
        Group {
            if let model {
                ReviewScreen(model: model)
                    .id(ObjectIdentifier(model))
            } else {
                // Opening takes a few milliseconds; nothing to show meanwhile (no spinner).
                Color.clear
            }
        }
        .task(id: loadKey) {
            guard let services else { return }
            let applying = target
            let opening = openingTarget
            model?.close()
            let loaded = await ReviewModel.load(lectureID: lectureID, services: services, target: opening, realign: realign)
            // A newer load (another recording or deck arrived, the screen closed) replaced this one.
            guard !Task.isCancelled else {
                loaded?.discard()
                return
            }
            loaded?.inspectorTab = renderTab ?? ReviewInspectorTab(rawValue: storedTab) ?? .slide
            appliedTarget = applying
            movedTo = nil
            model = loaded
            // Opened again while this load ran: move there now.
            if target != applying { apply(target) }
        }
        .onChange(of: target) { _, target in
            apply(target)
        }
        .onChange(of: model?.inspectorTab) { _, tab in
            if let tab, tab.rawValue != storedTab { storedTab = tab.rawValue }
        }
        .onChange(of: model?.requestedRecordingID) { _, recordingID in
            if let recordingID { chosenRecording = recordingID }
        }
        .onChange(of: model?.requestedMoment) { _, moment in
            guard let moment, let recordingID = moment.recordingID else { return }
            movedTo = moment
            chosenRecording = recordingID
        }
        // nl: View ▸ Zoom In / Zoom Out / Actual Size scale the transcript and the notes' text
        // (both chromes; the Mac's Notes pane applies its own); the toolbar, tabs, rail, stage
        // and player stay.
        .contentZoomable()
    }

    /// Opened again at another slide or time (a search hit, Today): move there, once.
    private func apply(_ target: ReviewTarget) {
        guard let model, appliedTarget != target else { return }
        appliedTarget = target
        // A moment without a recording is on the lecture's first (`ReviewTarget.recordingID`).
        let wanted = target.recordingID ?? (target.time == nil ? nil : recordings.first?.id)
        if let recordingID = wanted, recordingID != model.recording?.id {
            // On another recording of the lecture: that one loads at the target.
            appliedTarget = nil
            chosenRecording = recordingID
            return
        }
        let session = model.session
        Task { await session.open(page: target.page, time: target.time, plays: target.plays, resume: nil) }
    }

    /// The recording on screen: the one picked (or moved to by a later target), else the one the
    /// target names, else the lecture's first.
    private var recordingID: Recording.ID? {
        let ids = recordings.map(\.id)
        if let chosenRecording, ids.contains(chosenRecording) { return chosenRecording }
        if let targeted = target.recordingID, ids.contains(targeted) { return targeted }
        return ids.first
    }

    private var loadKey: LoadKey {
        let link = deckLinks.last
        return LoadKey(
            lectureID: lectureID, recordingID: recordingID, recordingCount: recordings.count, deckID: link?.deckID,
            firstPage: link?.firstPage, lastPage: link?.lastPage
        )
    }

    /// Where a load opens: the target the first time; after that (a deck or recording filed into
    /// the open lecture, another recording picked) where review is now, or the picked recording
    /// from where review left off.
    private var openingTarget: ReviewTarget {
        if let movedTo, movedTo.recordingID == recordingID { return movedTo }
        guard let model, appliedTarget == target else {
            var opening = target
            opening.recordingID = recordingID
            return opening
        }
        if model.recording?.id == recordingID {
            return ReviewTarget(page: model.session.shownPage, time: model.player?.time, recordingID: recordingID)
        }
        return ReviewTarget(recordingID: recordingID)
    }

    /// A new recording or deck (filing, Change), another range of it (mr: the agent's
    /// link_deck_pages, continuation detection), or another recording picked, reloads the screen.
    private struct LoadKey: Hashable {
        var lectureID: Lecture.ID
        var recordingID: Recording.ID?
        var recordingCount: Int
        var deckID: Deck.ID?
        var firstPage: Int?
        var lastPage: Int?
    }
}

/// The loaded screen. Its own body depends only on the timed spans (re-alignment); everything
/// that changes while playing or typing is read by the small views that show it.
struct ReviewScreen: View {
    let model: ReviewModel

    private let spansQuery: FetchAll<LectureDeckSpan>
    private var spans: [LectureDeckSpan] { spansQuery.wrappedValue }
    @Environment(\.reviewChrome) private var chrome
    @Environment(\.undoManager) private var undoManager
    @Environment(\.deleteFromLibrary) private var deleteFromLibrary
    #if os(iOS)
    /// ma: the agent panel is expanded into the window's trailing column: it takes the
    /// inspector's place until it shrinks (never two inspectors).
    @Environment(\.agentPanelExpanded) private var agentPanelExpanded
    #endif

    init(model: ReviewModel) {
        self.model = model
        let lectureID = model.lecture.id
        let recordingID = model.recording?.id ?? UUID()
        spansQuery = FetchAll(
            LectureDeckSpan
                .where { $0.lectureID.eq(lectureID) && $0.recordingID.eq(recordingID) && $0.startTime.isNot(nil) }
                .order(by: \.startTime),
            database: model.services.database
        )
    }

    var body: some View {
        let model = model
        let timeline = SlideTimeline(spans)
        Group {
            switch chrome {
            case .window:
                ReviewContent(model: model, timeline: timeline)
                    #if os(macOS)
                    // A click on the slide, the rail, the transcript or the player ends typing in
                    // a note or the agent's composer: ← / → and Space are the review's again.
                    .endsTypingOnClick()
                    #endif
                    // The Window menu's name; the toolbar shows its own, larger title.
                    .navigationTitle(title)
                    #if os(macOS)
                    .navigationSubtitle(subtitle)
                    .toolbar(removing: .title)
                    // No line under the toolbar across the content (mockup 03: the slide's top
                    // edge is the first thing under the title), as on the live screen.
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            ReviewTitle(title: title, subtitle: subtitle)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        // Without the system title nothing pushes the items to the trailing edge.
                        ToolbarSpacer(.flexible)
                        #if os(iOS)
                        ReviewToolbar(model: model, isPanelExpanded: agentPanelExpanded)
                        #else
                        ReviewToolbar(model: model)
                        #endif
                    }
                    #if os(macOS)
                    // The notes as the screen's side pane: built again only for another loaded
                    // review; its header's accessory is the tab picker.
                    .pane(.notes, identity: ObjectIdentifier(model), accessory: { NotesTabPicker(model: model) }) {
                        ReviewNotesPane(model: model)
                    }
                    #else
                    .modifier(ReviewInspectorColumn(isPanelExpanded: agentPanelExpanded, isPresented: inspectorShown) {
                        ReviewInspector(model: model, isShown: !agentPanelExpanded)
                            .inspectorColumnWidth(min: 260, ideal: ReviewInspector.width, max: 440)
                    })
                    #endif
            case .snapshot:
                SnapshotChrome(model: model, title: title, subtitle: subtitle) {
                    ReviewContent(model: model, timeline: timeline)
                }
            }
        }
        .background(ReviewActionsPublisher(model: model))
        #if os(macOS)
        // ← / → and Page Up / Page Down page the slides while no text in the window has the keyboard.
        .background(ReviewSlideKeys(model: model))
        #endif
        .background(ReviewAgentContext(model: model))
        .background(DrawingFollowGuard(model: model))
        .onChange(of: timeline, initial: true) { _, timeline in
            model.session.update(timeline: timeline)
        }
        // Edit ▸ Delete Lecture… / Delete Slides… / Delete Recording… act on what is open here.
        .focusedSceneValue(\.openLibraryItems, deleteFromLibrary.map { delete in
            OpenLibraryItems(lecture: model.lecture.id, deck: model.deckID, recording: model.recording?.id, delete: delete)
        })
        .onDisappear { [undoManager] in
            model.close()
            // A flag's undo step never outlives its screen (ink's go with each page's canvas).
            undoManager?.removeAllActions(withTarget: model.flagUndo)
        }
    }

    #if os(iOS)
    /// The inspector shows unless hidden, or while the agent panel is expanded in its place.
    private var inspectorShown: Binding<Bool> {
        let model = model
        let expanded = agentPanelExpanded
        return Binding(
            get: { model.showsInspector && !expanded },
            set: { shown in if !expanded { model.showsInspector = shown } }
        )
    }
    #endif

    private var title: String {
        model.lecture.title.isEmpty ? String(localized: "Lecture") : model.lecture.title
    }

    /// "Data Centers · Tue 13 Oct", then (mr) " · slides 38–88 of 88" when the lecture shows
    /// part of its deck.
    private var subtitle: Text {
        let course = model.course?.name ?? ""
        var meta: Text
        if let held = model.lecture.heldAt {
            let date = Text(held, format: DayText.style())
            meta = course.isEmpty ? date : Text("\(course) · \(date)")
        } else {
            meta = Text(course)
        }
        guard let range = model.rangeText else { return meta }
        let separator: String = course.isEmpty && model.lecture.heldAt == nil ? "" : " · "
        meta = Text("\(meta)\(separator)\(range)")
        return meta
    }

    /// The player's distance from the bottom edge.
    static let playerBottom: CGFloat = 14
    /// Room under the rail and transcript: the player, its distance from the bottom edge and 8 pt
    /// above it.
    static let playerClearance: CGFloat = PlayerBar.height + playerBottom + 8
}

#if os(iOS)
/// The iPad's notes inspector, left out entirely while the agent panel is expanded into the
/// window's trailing column (as Calendar's Deadlines): a hidden inspector still kept its column's
/// room. The `if` makes the review a new view each time the panel expands or shrinks: what that
/// would cost is kept in `ReviewModel` (the transcript's lines and where the list was scrolled);
/// the slide comes from the deck's cache in the same frame.
private struct ReviewInspectorColumn<Inspector: View>: ViewModifier {
    let isPanelExpanded: Bool
    let isPresented: Binding<Bool>
    @ViewBuilder let inspector: () -> Inspector

    func body(content: Content) -> some View {
        if isPanelExpanded {
            content
        } else {
            content.inspector(isPresented: isPresented, content: inspector)
        }
    }
}
#endif

/// ma: tells the agent panel what the review shows (the lecture, the recording, the slide on
/// screen) and, read at ↩, the playhead. Its own view, so the slide changing never re-renders the
/// screen. ln: a notes passage taken to the chat from Summary goes with the next message
/// (`refine` runs once per message).
private struct ReviewAgentContext: View {
    let model: ReviewModel

    var body: some View {
        let model = model
        let onFirst = model.recording == nil || model.recording?.id == model.recordings.first?.id
        let recordingID = onFirst ? nil : model.recording?.id
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .agentContext(
                AgentContext(
                    screen: .lecture, courseID: model.course?.id, lectureID: model.lecture.id, recordingID: recordingID,
                    page: model.session.shownPage, notesPassage: model.notesPassage
                ),
                refine: {
                    if model.notesPassage != nil {
                        Task { @MainActor in model.notesPassage = nil }
                    }
                    return AgentContext(
                        screen: .lecture, lectureID: model.lecture.id, recordingID: recordingID, page: model.session.shownPage,
                        time: model.player?.time
                    )
                }
            )
    }
}

/// The window title (mockup 03): the lecture in the title style, course and day under it.
struct ReviewTitle: View {
    /// Past the toolbar's own leading inset, so the title starts about 20 pt from the content's
    /// edge.
    static let leadingInset: CGFloat = 11

    let title: String
    let subtitle: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
            subtitle
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.leading, Self.leadingInset)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The toolbar: previous / "16 / 88" / next as one glass group, then (M6, Mac, with a deck) the ink
/// group [Pen, Highlighter, (Eraser), Flag] in its own glass. On the Mac the Notes pane's toggle is
/// the app's (the pane toggles at the toolbar's end). On the iPad the inspector's own header hides
/// it; while it is hidden, a button of its own brings it back (the header's item is gone then, see
/// `ReviewInspector`), so exactly one of the two is in the toolbar.
struct ReviewToolbar: ToolbarContent {
    let model: ReviewModel
    #if os(iOS)
    /// ma: the agent panel is expanded in the inspector's place: no Show Inspector meanwhile.
    var isPanelExpanded = false
    #endif

    var body: some ToolbarContent {
        if model.recordings.count > 1 {
            // A second recording of the class (Stop and Record again, a backup recorder).
            ToolbarItem(placement: .primaryAction) {
                RecordingPicker(model: model)
            }
        }
        if model.deck != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                SlideStepper(session: model.session, deckID: model.deckID)
            }
            #if os(macOS)
            // M6: [Pen, Highlighter, (Eraser), Flag] in its own glass after the stepper.
            if model.canDraw {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    InkToolButtons(model: model)
                }
            }
            #endif
        }
        #if os(iOS)
        if !model.showsInspector, !isPanelExpanded {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showsInspector = true
                } label: {
                    Label("Show Inspector", systemImage: "sidebar.trailing")
                }
                .help(Text("Show Inspector"))
            }
        }
        #endif
    }
}

/// Which of the lecture's recordings plays, by its start ("12:17").
/// Its menu ends with Delete Recording… for the one playing (the window confirms, Edit ▸ Undo).
struct RecordingPicker: View {
    let model: ReviewModel
    @Environment(\.deleteFromLibrary) private var deleteFromLibrary

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { model.recording?.id },
                set: { id in if let id { model.requestedRecordingID = id } }
            )) {
                ForEach(model.recordings) { recording in
                    Text(recording.startedAt, format: .dateTime.hour().minute())
                        .monospacedDigit()
                        .tag(Optional(recording.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            if let deleteFromLibrary, let recording = model.recording {
                Divider()
                Button("Delete Recording…", role: .destructive) { deleteFromLibrary(.recording(recording.id)) }
            }
        } label: {
            Label {
                if let recording = model.recording {
                    Text(recording.startedAt, format: .dateTime.hour().minute())
                        .monospacedDigit()
                } else {
                    Text("Recording")
                }
            } icon: {
                Image(systemName: "waveform")
            }
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(Text("Recording"))
        .fixedSize()
    }
}

/// Previous slide, "16 / 88", next slide; the count's menu has Delete Slides… (the window
/// confirms, Edit ▸ Undo).
struct SlideStepper: View {
    let session: ReviewSession
    var deckID: Deck.ID?
    @Environment(\.deleteFromLibrary) private var deleteFromLibrary

    var body: some View {
        Button {
            session.previousSlide()
        } label: {
            Label("Previous Slide", systemImage: "chevron.left")
        }
        .disabled(!session.canGoPrevious)
        Text(verbatim: "\(session.shownPage ?? 0) / \(session.pageCount)")
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 10)
            .accessibilityLabel(Text("Slide \(session.shownPage ?? 0) of \(session.pageCount)"))
            .contextMenu {
                if let deleteFromLibrary, let deckID {
                    Button("Delete Slides…", role: .destructive) { deleteFromLibrary(.deck(deckID)) }
                }
            }
        Button {
            session.nextSlide()
        } label: {
            Label("Next Slide", systemImage: "chevron.right")
        }
        .disabled(!session.canGoNext)
    }
}

/// What off-screen snapshots draw in place of the window toolbar and the notes: the same title,
/// toolbar items and notes (with their tab picker), laid out inline.
private struct SnapshotChrome<Content: View>: View {
    let model: ReviewModel
    let title: String
    let subtitle: Text
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ReviewTitle(title: title, subtitle: subtitle)
                        .padding(.leading, -ReviewTitle.leadingInset)
                    Spacer()
                    if model.deck != nil {
                        HStack(spacing: 12) {
                            SlideStepper(session: model.session, deckID: model.deckID)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .reviewGlass(in: Capsule())
                        #if os(macOS)
                        if model.canDraw {
                            SnapshotInkTools(model: model)
                        }
                        #endif
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .frame(height: 52)
                content
            }
            Divider()
            ReviewInspector(model: model)
                .frame(width: ReviewInspector.width)
        }
        .background(.background)
    }
}
