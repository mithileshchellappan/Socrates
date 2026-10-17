import Review
import StudyCore
import SwiftUI

/// What the review screen in the key window can do right now, published as a focused scene value
/// for `ReviewCommands`. Everything is off while a text field has focus (a note, or the window's
/// search field), so typing never plays, pages or marks.
public struct ReviewActions {
    public var hasAudio: Bool
    public var isPlaying: Bool
    public var canGoPrevious: Bool
    public var canGoNext: Bool
    public var canFollow: Bool
    public var isFollowing: Bool
    public var canSetSlideStart: Bool
    public var isReviewed: Bool
    public var isEditingText: Bool

    public var playPause: () -> Void
    public var back: () -> Void
    public var forward: () -> Void
    public var previousSlide: () -> Void
    public var nextSlide: () -> Void
    public var toggleFollow: () -> Void
    public var slideStartsHere: () -> Void
    public var toggleReviewed: () -> Void

    public init(
        hasAudio: Bool, isPlaying: Bool, canGoPrevious: Bool, canGoNext: Bool, canFollow: Bool, isFollowing: Bool,
        canSetSlideStart: Bool, isReviewed: Bool, isEditingText: Bool,
        playPause: @escaping () -> Void, back: @escaping () -> Void, forward: @escaping () -> Void,
        previousSlide: @escaping () -> Void, nextSlide: @escaping () -> Void, toggleFollow: @escaping () -> Void,
        slideStartsHere: @escaping () -> Void, toggleReviewed: @escaping () -> Void
    ) {
        self.hasAudio = hasAudio
        self.isPlaying = isPlaying
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        self.canFollow = canFollow
        self.isFollowing = isFollowing
        self.canSetSlideStart = canSetSlideStart
        self.isReviewed = isReviewed
        self.isEditingText = isEditingText
        self.playPause = playPause
        self.back = back
        self.forward = forward
        self.previousSlide = previousSlide
        self.nextSlide = nextSlide
        self.toggleFollow = toggleFollow
        self.slideStartsHere = slideStartsHere
        self.toggleReviewed = toggleReviewed
    }

    var playbackEnabled: Bool { hasAudio && !isEditingText }
    var previousEnabled: Bool { canGoPrevious && !isEditingText }
    var nextEnabled: Bool { canGoNext && !isEditingText }
    var followEnabled: Bool { canFollow && !isEditingText }
    var slideStartEnabled: Bool { canSetSlideStart && !isEditingText }
    var reviewedEnabled: Bool { !isEditingText }
}

extension FocusedValues {
    /// The lecture review screen in the key window, if any.
    @Entry public var lectureReview: ReviewActions?
}

/// The Review menu: Play/Pause (Space), Back/Forward 15 Seconds (⌥← / ⌥→), Previous/Next Slide
/// (← / →), Follow Playback (⇧⌘F), Slide Starts Here (⌘\), Mark as Reviewed (⇧⌘R). Reads the
/// focused review screen's actions; everything is disabled while a text field has focus.
///
///     WindowGroup { … }.commands { ReviewCommands() }
public struct ReviewCommands: Commands {
    @FocusedValue(\.lectureReview) private var review

    public init() {}

    public var body: some Commands {
        CommandMenu("Review") {
            Button(review?.isPlaying == true ? "Pause" : "Play") { review?.playPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(review?.playbackEnabled != true)
            Button("Back 15 Seconds") { review?.back() }
                .keyboardShortcut(.leftArrow, modifiers: [.option])
                .disabled(review?.playbackEnabled != true)
            Button("Forward 15 Seconds") { review?.forward() }
                .keyboardShortcut(.rightArrow, modifiers: [.option])
                .disabled(review?.playbackEnabled != true)
            Divider()
            Button("Previous Slide") { review?.previousSlide() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(review?.previousEnabled != true)
            Button("Next Slide") { review?.nextSlide() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(review?.nextEnabled != true)
            Toggle("Follow Playback", isOn: Binding(
                get: { review?.isFollowing == true },
                set: { _ in review?.toggleFollow() }
            ))
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(review?.followEnabled != true)
            Divider()
            Button("Slide Starts Here") { review?.slideStartsHere() }
                .keyboardShortcut("\\", modifiers: [.command])
                .disabled(review?.slideStartEnabled != true)
            Toggle("Mark as Reviewed", isOn: Binding(
                get: { review?.isReviewed == true },
                set: { _ in review?.toggleReviewed() }
            ))
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(review?.reviewedEnabled != true)
        }
    }
}

/// Publishes the screen's `ReviewActions`. Its own view, so the state it reads (playing, slide,
/// reviewed) never re-renders the screen.
struct ReviewActionsPublisher: View {
    let model: ReviewModel

    private let lectureQuery: FetchAll<Lecture>
    private var lecture: [Lecture] { lectureQuery.wrappedValue }
    @Environment(\.isSearching) private var isSearching

    init(model: ReviewModel) {
        self.model = model
        let lectureID = model.lecture.id
        lectureQuery = FetchAll(Lecture.where { $0.id.eq(lectureID) }, database: model.services.database)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .focusedSceneValue(\.lectureReview, actions)
    }

    private var actions: ReviewActions {
        let model = model
        let session = model.session
        let player = model.player
        let isReviewed = (lecture.first ?? model.lecture).reviewedAt != nil
        return ReviewActions(
            hasAudio: player?.hasAudio == true,
            isPlaying: player?.isPlaying == true,
            canGoPrevious: session.canGoPrevious && model.deck != nil,
            canGoNext: session.canGoNext && model.deck != nil,
            canFollow: session.canFollow,
            isFollowing: session.isFollowing,
            canSetSlideStart: model.canSetAnchor && session.shownPage != nil,
            isReviewed: isReviewed,
            isEditingText: model.isEditingText || isSearching,
            playPause: { session.togglePlayPause() },
            back: { session.skip(by: -LecturePlayer.skipInterval) },
            forward: { session.skip(by: LecturePlayer.skipInterval) },
            previousSlide: { session.previousSlide() },
            nextSlide: { session.nextSlide() },
            toggleFollow: { session.toggleFollowing() },
            slideStartsHere: { model.slideStartsHere() },
            toggleReviewed: { model.toggleReviewed(isReviewed: isReviewed) }
        )
    }
}
