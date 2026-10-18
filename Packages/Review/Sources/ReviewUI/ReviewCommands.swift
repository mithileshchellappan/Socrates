import Review
import StudyCore
import StudyUI
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

    /// The thumbnails (there with a deck) and the transcript under the slide (there with a deck
    /// and a recording) collapse; typing does not turn these off.
    public var canToggleThumbnails: Bool
    public var areThumbnailsCollapsed: Bool
    public var canToggleTranscript: Bool
    public var isTranscriptCollapsed: Bool
    public var toggleThumbnails: () -> Void
    public var toggleTranscript: () -> Void

    /// M6 (Mac): drawing on the slide (with a deck) and flags (with a recording).
    public var canDraw: Bool
    /// The tool on; nil while not drawing.
    public var inkTool: InkTool?
    public var canFlag: Bool
    public var toggleInkTool: (InkTool) -> Void
    public var stopDrawing: () -> Void
    public var flag: () -> Void

    public init(
        hasAudio: Bool, isPlaying: Bool, canGoPrevious: Bool, canGoNext: Bool, canFollow: Bool, isFollowing: Bool,
        canSetSlideStart: Bool, isReviewed: Bool, isEditingText: Bool,
        playPause: @escaping () -> Void, back: @escaping () -> Void, forward: @escaping () -> Void,
        previousSlide: @escaping () -> Void, nextSlide: @escaping () -> Void, toggleFollow: @escaping () -> Void,
        slideStartsHere: @escaping () -> Void, toggleReviewed: @escaping () -> Void,
        canToggleThumbnails: Bool = false, areThumbnailsCollapsed: Bool = false,
        canToggleTranscript: Bool = false, isTranscriptCollapsed: Bool = false,
        toggleThumbnails: @escaping () -> Void = {}, toggleTranscript: @escaping () -> Void = {},
        canDraw: Bool = false, inkTool: InkTool? = nil, canFlag: Bool = false,
        toggleInkTool: @escaping (InkTool) -> Void = { _ in }, stopDrawing: @escaping () -> Void = {},
        flag: @escaping () -> Void = {}
    ) {
        self.canDraw = canDraw
        self.inkTool = inkTool
        self.canFlag = canFlag
        self.toggleInkTool = toggleInkTool
        self.stopDrawing = stopDrawing
        self.flag = flag
        self.canToggleThumbnails = canToggleThumbnails
        self.areThumbnailsCollapsed = areThumbnailsCollapsed
        self.canToggleTranscript = canToggleTranscript
        self.isTranscriptCollapsed = isTranscriptCollapsed
        self.toggleThumbnails = toggleThumbnails
        self.toggleTranscript = toggleTranscript
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
    var drawEnabled: Bool { canDraw && !isEditingText }
    /// The eraser joins while a tool is on.
    var eraserEnabled: Bool { drawEnabled && inkTool != nil }
    var stopDrawingEnabled: Bool { inkTool != nil && !isEditingText }
    var flagEnabled: Bool { canFlag && !isEditingText }
}

extension FocusedValues {
    /// The lecture review screen in the key window, if any.
    @Entry public var lectureReview: ReviewActions?
}

/// The Review menu: Play/Pause (Space), Back/Forward 15 Seconds (⌥← / ⌥→), Previous/Next Slide
/// (← / →), Follow Playback (⇧⌘F), Slide Starts Here (⌘\), Mark as Reviewed (⇧⌘R); M6 on the Mac:
/// Flag (F), Pen (P), Highlighter (H), Eraser (E, while drawing), Stop Drawing (Esc). Reads the
/// focused review screen's actions; everything is disabled while a text field has focus. In the
/// View menu after the sidebar: Hide/Show Thumbnails (⌥⌘1) and Hide/Show Transcript (⌥⌘2).
///
///     WindowGroup { … }.commands { ReviewCommands() }
public struct ReviewCommands: Commands {
    @FocusedValue(\.lectureReview) private var review

    public init() {}

    public var body: some Commands {
        // A menu item with a key equivalent takes the key even while disabled: the plain and ⌥
        // keys are attached only while the review screen is in the key window and no text field
        // has focus (a note, the search field), and the ⌘ ones only while it is focused (Lecture ▸
        // Record has ⇧⌘R in the live window).
        let keys = review.map { !$0.isEditingText } ?? false
        let focused = review != nil
        CommandMenu("Review") {
            Button(review?.isPlaying == true ? "Pause" : "Play") { review?.playPause() }
                .keyboardShortcut(keys ? KeyboardShortcut(.space, modifiers: []) : nil)
                .disabled(review?.playbackEnabled != true)
            Button("Back 15 Seconds") { review?.back() }
                .keyboardShortcut(keys ? KeyboardShortcut(.leftArrow, modifiers: [.option]) : nil)
                .disabled(review?.playbackEnabled != true)
            Button("Forward 15 Seconds") { review?.forward() }
                .keyboardShortcut(keys ? KeyboardShortcut(.rightArrow, modifiers: [.option]) : nil)
                .disabled(review?.playbackEnabled != true)
            Divider()
            Button("Previous Slide") { review?.previousSlide() }
                .keyboardShortcut(keys ? KeyboardShortcut(.leftArrow, modifiers: []) : nil)
                .disabled(review?.previousEnabled != true)
            Button("Next Slide") { review?.nextSlide() }
                .keyboardShortcut(keys ? KeyboardShortcut(.rightArrow, modifiers: []) : nil)
                .disabled(review?.nextEnabled != true)
            Toggle("Follow Playback", isOn: Binding(
                get: { review?.isFollowing == true },
                set: { _ in review?.toggleFollow() }
            ))
            .keyboardShortcut(focused ? KeyboardShortcut("f", modifiers: [.command, .shift]) : nil)
            .disabled(review?.followEnabled != true)
            Divider()
            #if os(macOS)
            // M6: the student's flag at the playhead (no text, no dialog; Edit ▸ Undo removes it).
            Button("Flag") { review?.flag() }
                .keyboardShortcut(review?.flagEnabled == true ? KeyboardShortcut("f", modifiers: []) : nil)
                .disabled(review?.flagEnabled != true)
            #endif
            Button("Slide Starts Here") { review?.slideStartsHere() }
                .keyboardShortcut(focused ? KeyboardShortcut("\\", modifiers: [.command]) : nil)
                .disabled(review?.slideStartEnabled != true)
            Toggle("Mark as Reviewed", isOn: Binding(
                get: { review?.isReviewed == true },
                set: { _ in review?.toggleReviewed() }
            ))
            .keyboardShortcut(focused ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
            .disabled(review?.reviewedEnabled != true)
            #if os(macOS)
            // M6: drawing on the slide (pen and highlighter one at a time, the eraser while
            // drawing, Esc ends it). Plain keys, attached only while they work (decision 161).
            Divider()
            inkToggle("Pen", .pen, key: "p", enabled: review?.drawEnabled == true)
            inkToggle("Highlighter", .highlighter, key: "h", enabled: review?.drawEnabled == true)
            inkToggle("Eraser", .eraser, key: "e", enabled: review?.eraserEnabled == true)
            Button("Stop Drawing") { review?.stopDrawing() }
                .keyboardShortcut(review?.stopDrawingEnabled == true ? KeyboardShortcut(.escape, modifiers: []) : nil)
                .disabled(review?.stopDrawingEnabled != true)
            #endif
        }
        CommandGroup(after: .sidebar) {
            Button(review?.areThumbnailsCollapsed == true ? LocalizedStringKey("Show Thumbnails") : "Hide Thumbnails") {
                review?.toggleThumbnails()
            }
            .keyboardShortcut(focused ? KeyboardShortcut("1", modifiers: [.command, .option]) : nil)
            .disabled(review?.canToggleThumbnails != true)
            Button(review?.isTranscriptCollapsed == true ? LocalizedStringKey("Show Transcript") : "Hide Transcript") {
                review?.toggleTranscript()
            }
            .keyboardShortcut(focused ? KeyboardShortcut("2", modifiers: [.command, .option]) : nil)
            .disabled(review?.canToggleTranscript != true)
        }
    }

    #if os(macOS)
    private func inkToggle(_ title: LocalizedStringKey, _ tool: InkTool, key: Character, enabled: Bool) -> some View {
        Toggle(title, isOn: Binding(
            get: { review?.inkTool == tool },
            set: { _ in review?.toggleInkTool(tool) }
        ))
        .keyboardShortcut(enabled ? KeyboardShortcut(KeyEquivalent(key), modifiers: []) : nil)
        .disabled(!enabled)
    }
    #endif
}

/// Publishes the screen's `ReviewActions`. Its own view, so the state it reads (playing, slide,
/// reviewed) never re-renders the screen.
struct ReviewActionsPublisher: View {
    let model: ReviewModel

    private let lectureQuery: FetchAll<Lecture>
    private var lecture: [Lecture] { lectureQuery.wrappedValue }
    /// The window's search field has keyboard focus (not merely a query in it: `isSearching`
    /// stays true until the search is cancelled, which would detach the review keys while a
    /// search hit plays).
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused
    /// The window's: Flag's undo step goes there (as the ink canvas's do).
    @Environment(\.undoManager) private var undoManager
    /// The screen's layout (`ReviewContent` reads the same value and animates the change).
    @AppStorage(ReviewLayout.storageKey) private var layout = ReviewLayout()

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
        let layout = $layout
        let undoManager = undoManager
        return ReviewActions(
            hasAudio: player?.hasAudio == true,
            isPlaying: player?.isPlaying == true,
            canGoPrevious: session.canGoPrevious && model.deck != nil,
            canGoNext: session.canGoNext && model.deck != nil,
            canFollow: session.canFollow,
            isFollowing: session.isFollowing,
            canSetSlideStart: model.canSetAnchor && session.shownPage != nil,
            isReviewed: isReviewed,
            isEditingText: model.isEditingText || model.isComposingChat || isSearchFieldFocused,
            playPause: { session.togglePlayPause() },
            back: { session.skip(by: -LecturePlayer.skipInterval) },
            forward: { session.skip(by: LecturePlayer.skipInterval) },
            previousSlide: { session.previousSlide() },
            nextSlide: { session.nextSlide() },
            toggleFollow: { session.toggleFollowing() },
            slideStartsHere: { model.slideStartsHere() },
            toggleReviewed: { model.toggleReviewed(isReviewed: isReviewed) },
            canToggleThumbnails: model.deck != nil,
            areThumbnailsCollapsed: layout.wrappedValue.isRailCollapsed,
            canToggleTranscript: model.deck != nil && model.recording != nil,
            isTranscriptCollapsed: layout.wrappedValue.isTranscriptCollapsed,
            toggleThumbnails: { layout.wrappedValue.isRailCollapsed.toggle() },
            toggleTranscript: { layout.wrappedValue.isTranscriptCollapsed.toggle() },
            canDraw: model.canDraw,
            inkTool: model.inkTool,
            canFlag: model.canFlag,
            toggleInkTool: { model.toggleInkTool($0) },
            stopDrawing: { model.stopDrawing() },
            flag: { model.flag(undoManager: undoManager) }
        )
    }
}
