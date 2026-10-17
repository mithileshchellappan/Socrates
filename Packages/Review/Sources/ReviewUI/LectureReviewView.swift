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
/// default database and `ReviewCommands` (Space, ⌥←/⌥→, ←/→, ⇧⌘F, ⌘\, ⇧⌘R).
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
        .task(id: LoadKey(lectureID: lectureID, recordingID: recordings.first?.id, deckID: deckLinks.last?.deckID)) {
            guard let services else { return }
            model?.close()
            let loaded = await ReviewModel.load(lectureID: lectureID, services: services, target: target, realign: realign)
            loaded?.inspectorTab = inspectorTab
            model = loaded
        }
        .onChange(of: target) { _, target in
            // Opened again at another slide or time (a search hit, Today): move there.
            guard let session = model?.session else { return }
            Task { await session.open(page: target.page, time: target.time, plays: target.plays, resume: nil) }
        }
    }

    /// A new recording or deck (filing, Change) reopens the screen.
    private struct LoadKey: Hashable {
        var lectureID: Lecture.ID
        var recordingID: Recording.ID?
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
    @State private var column: CGSize = .zero

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
                content(timeline: timeline)
                    .navigationTitle(model.lecture.title.isEmpty ? String(localized: "Lecture") : model.lecture.title)
                    #if os(macOS)
                    .navigationSubtitle(subtitle)
                    #endif
                    .toolbar { ReviewToolbar(model: model) }
                    .inspector(isPresented: Bindable(model).showsInspector) {
                        ReviewInspector(model: model)
                            .inspectorColumnWidth(min: 260, ideal: 320, max: 440)
                    }
            case .snapshot:
                SnapshotChrome(model: model, title: model.lecture.title, subtitle: subtitle) {
                    content(timeline: timeline)
                }
            }
        }
        .background(ReviewActionsPublisher(model: model))
        .onChange(of: timeline, initial: true) { _, timeline in
            model.session.update(timeline: timeline)
        }
        .onDisappear { model.close() }
    }

    private var subtitle: Text {
        let course = model.course?.name ?? ""
        guard let held = model.lecture.heldAt else { return Text(course) }
        let date = Text(held, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return course.isEmpty ? date : Text("\(course) · \(date)")
    }

    /// Rail | slide over transcript, with the player floating over the bottom.
    private func content(timeline: SlideTimeline) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let deck = model.deck {
                SlideRail(model: model, deck: deck)
                    .frame(width: SlideRail.width)
            }
            VStack(spacing: 12) {
                if let deck = model.deck {
                    if model.recording == nil {
                        SlideStage(model: model, deck: deck)
                            .frame(maxHeight: .infinity)
                    } else {
                        SlideStage(model: model, deck: deck)
                            .frame(height: stageHeight(deck))
                    }
                }
                if model.recording != nil {
                    TranscriptZone(model: model, timeline: timeline)
                        .frame(maxHeight: .infinity)
                } else if model.deck == nil {
                    ContentUnavailableView {
                        Image(systemName: "rectangle.on.rectangle.slash")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { column = $0 }
        }
        .padding(.leading, model.deck == nil ? 16 : 8)
        .padding(.trailing, 16)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let player = model.player {
                PlayerBar(model: model, player: player, timeline: timeline)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
        .background(.background)
    }

    /// The slide's height over the transcript: its full width, at most about half the column.
    private func stageHeight(_ deck: SlideDeck) -> CGFloat {
        let aspect = deck.aspectRatio(page: 1)
        guard column.width > 0, aspect > 0 else { return 0 }
        return min(column.width / aspect, max(160, column.height * 0.5))
    }
}

/// The toolbar: previous / "16 / 88" / next as one glass group, and the inspector toggle.
struct ReviewToolbar: ToolbarContent {
    let model: ReviewModel

    var body: some ToolbarContent {
        if model.deck != nil {
            ToolbarItemGroup(placement: .primaryAction) {
                SlideStepper(session: model.session)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
        }
    }
}

/// Previous slide, "16 / 88", next slide.
struct SlideStepper: View {
    let session: ReviewSession

    var body: some View {
        Button {
            session.previousSlide()
        } label: {
            Label("Previous Slide", systemImage: "chevron.left")
        }
        .disabled(!session.canGoPrevious)
        Text(verbatim: "\(session.shownPage ?? 0) / \(session.pageCount)")
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.horizontal, 2)
            .accessibilityLabel(Text("Slide \(session.shownPage ?? 0) of \(session.pageCount)"))
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                        subtitle
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer()
                    if model.deck != nil {
                        HStack(spacing: 12) {
                            SlideStepper(session: model.session)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .reviewGlass(in: Capsule())
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 14)
                .frame(height: 52)
                content
            }
            Divider()
            ReviewInspector(model: model)
                .frame(width: 320)
                .background(.background.secondary)
        }
        .background(.background)
    }
}
