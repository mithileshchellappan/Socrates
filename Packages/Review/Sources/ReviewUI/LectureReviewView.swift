import Capture
import Review
import StudyCore
import StudyUI
import SwiftUI

/// The lecture review screen (PRD #14, mockup 03): the slide on screen, a rail of thumbnails, the
/// transcript grouped by slide visit, a floating player on one recording clock, and an inspector
/// with the slide's notes (#15) or every note of the lecture. Clicking a line plays from it;
/// "Slide N Starts Here" sets a manual anchor and re-aligns at once through `realign` (#9).
///
/// The app passes `Realigner(services:).realign` and installs `\.studyServices`, SQLiteData's
/// default database and `ReviewCommands` (Space, ⌥←/⌥→, ←/→, ⇧⌘F, ⌘\, ⇧⌘R; M6 on the Mac: P, H, E,
/// F, Esc; View ⌥⌘1, ⌥⌘2).
///
/// - Without a deck there is no rail and no slide; without a recording no player and no
///   transcript; before the transcript exists the transcript zone shows the job's progress.
/// - Opens at `target` (page and/or time, optionally playing), else where review left off.
public struct LectureReviewView: View {
    private let lectureID: Lecture.ID
    private let target: ReviewTarget
    private let realign: @Sendable (Lecture.ID, Recording.ID) async throws -> Void

    @Environment(\.studyServices) private var services
    @Environment(\.reviewInspectorTab) private var inspectorTab
    private let recordingsQuery: FetchAll<Recording>
    private var recordings: [Recording] { recordingsQuery.wrappedValue }
    private let deckLinksQuery: FetchAll<LectureDeckSpan>
    private var deckLinks: [LectureDeckSpan] { deckLinksQuery.wrappedValue }
    @State private var model: ReviewModel?
    /// The target the screen has moved to already: it is applied once, not again on a reload.
    @State private var appliedTarget: ReviewTarget?
    /// The recording picked in the toolbar (a lecture with more than one).
    @State private var chosenRecording: Recording.ID?

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
            loaded?.inspectorTab = inspectorTab
            appliedTarget = applying
            model = loaded
            // Opened again while this load ran: move there now.
            if target != applying { apply(target) }
        }
        .onChange(of: target) { _, target in
            apply(target)
        }
        .onChange(of: model?.requestedRecordingID) { _, recordingID in
            if let recordingID { chosenRecording = recordingID }
        }
    }

    /// Opened again at another slide or time (a search hit, Today): move there, once.
    private func apply(_ target: ReviewTarget) {
        guard let model, appliedTarget != target else { return }
        appliedTarget = target
        if let recordingID = target.recordingID, recordingID != model.recording?.id {
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
        LoadKey(lectureID: lectureID, recordingID: recordingID, recordingCount: recordings.count, deckID: deckLinks.last?.deckID)
    }

    /// Where a load opens: the target the first time; after that (a deck or recording filed into
    /// the open lecture, another recording picked) where review is now, or the picked recording
    /// from where review left off.
    private var openingTarget: ReviewTarget {
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

    /// A new recording or deck (filing, Change), or another recording picked, reloads the screen.
    private struct LoadKey: Hashable {
        var lectureID: Lecture.ID
        var recordingID: Recording.ID?
        var recordingCount: Int
        var deckID: Deck.ID?
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
    /// ma: the agent panel is expanded into the window's trailing column: it takes the
    /// inspector's place until it shrinks (never two inspectors).
    @Environment(\.agentPanelExpanded) private var agentPanelExpanded

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
        let timeline = SlideTimeline(spans)
        Group {
            switch chrome {
            case .window:
                ReviewContent(model: model, timeline: timeline)
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
                        ReviewToolbar(model: model, isPanelExpanded: agentPanelExpanded)
                    }
                    .inspector(isPresented: inspectorShown) {
                        ReviewInspector(model: model, isShown: !agentPanelExpanded)
                            .inspectorColumnWidth(min: 260, ideal: ReviewInspector.width, max: 440)
                    }
            case .snapshot:
                SnapshotChrome(model: model, title: title, subtitle: subtitle) {
                    ReviewContent(model: model, timeline: timeline)
                }
            }
        }
        .background(ReviewActionsPublisher(model: model))
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

    /// The inspector shows unless hidden, or while the agent panel is expanded in its place.
    private var inspectorShown: Binding<Bool> {
        let model = model
        let expanded = agentPanelExpanded
        return Binding(
            get: { model.showsInspector && !expanded },
            set: { shown in if !expanded { model.showsInspector = shown } }
        )
    }

    private var title: String {
        model.lecture.title.isEmpty ? String(localized: "Lecture") : model.lecture.title
    }

    private var subtitle: Text {
        let course = model.course?.name ?? ""
        guard let held = model.lecture.heldAt else { return Text(course) }
        let date = Text(held, format: DayText.style())
        return course.isEmpty ? date : Text("\(course) · \(date)")
    }

    /// The player's distance from the bottom edge.
    static let playerBottom: CGFloat = 14
    /// Room under the rail and transcript: the player, its distance from the bottom edge and 8 pt
    /// above it.
    static let playerClearance: CGFloat = PlayerBar.height + playerBottom + 8
}

/// ma: tells the agent panel what the review shows (the lecture, the recording, the slide on
/// screen) and, read at ↩, the playhead. Its own view, so the slide changing never re-renders the
/// screen.
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
                    page: model.session.shownPage
                ),
                refine: {
                    AgentContext(
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
/// group [Pen, Highlighter, (Eraser), Flag] in its own glass. The inspector's own header hides
/// it; while it is hidden, a button of its own brings it back (the header's item is gone then, see
/// `ReviewInspector`), so exactly one of the two is in the toolbar.
struct ReviewToolbar: ToolbarContent {
    let model: ReviewModel
    /// ma: the agent panel is expanded in the inspector's place: no Show Inspector meanwhile.
    var isPanelExpanded = false

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

/// What off-screen snapshots draw in place of the window toolbar and inspector column: the same
/// title, toolbar items and inspector, laid out inline.
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
