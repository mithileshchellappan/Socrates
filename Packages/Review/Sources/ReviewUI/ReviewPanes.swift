import Capture
import Review
import StudyUI
import SwiftUI

/// Rail | slide over transcript, with the player floating over the bottom.
///
/// The rail's edge and the divider under the slide are the student's to move: drag, or
/// double-click to collapse the pane and bring it back (View ▸ Hide Thumbnails ⌥⌘1, Hide
/// Transcript ⌥⌘2). A collapsed transcript gives the slide its room; the player stays. The layout
/// is kept in the app's defaults (`ReviewLayout`), so every lecture opens the same way.
struct ReviewContent: View {
    let model: ReviewModel
    let timeline: SlideTimeline

    @AppStorage(ReviewLayout.storageKey) private var storedLayout = ReviewLayout()
    /// While an edge is dragged: the layout as the drag began, and as it is now. Written to the
    /// defaults once, when the drag ends.
    @State private var drag: Drag?
    @State private var column: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Drag: Equatable {
        var start: ReviewLayout
        var current: ReviewLayout
    }

    var body: some View {
        let layout = drag?.current ?? storedLayout
        let railCollapsed = model.deck != nil && layout.isRailCollapsed
        let transcriptCollapsed = model.deck != nil && model.recording != nil && layout.isTranscriptCollapsed
        HStack(alignment: .top, spacing: 0) {
            if let deck = model.deck {
                if !railCollapsed {
                    SlideRail(model: model, deck: deck)
                        .frame(width: SlideRail.width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                PaneDivider(
                    axis: .vertical,
                    isCollapsed: railCollapsed,
                    toggleLabel: railCollapsed ? Text("Show Thumbnails") : Text("Hide Thumbnails"),
                    changed: { dragRailEdge(by: $0) },
                    ended: endDrag,
                    toggle: { storedLayout.isRailCollapsed.toggle() }
                )
                .frame(width: ReviewLayout.railEdgeWidth)
                .frame(maxHeight: .infinity)
                .zIndex(1)
            }
            VStack(spacing: 0) {
                if let deck = model.deck {
                    if model.recording == nil {
                        SlideStage(model: model, deck: deck)
                            .frame(maxHeight: .infinity)
                    } else {
                        let geometry = slideColumn(deck)
                        SlideStage(model: model, deck: deck)
                            .frame(height: transcriptCollapsed ? nil : layout.slideHeight(in: geometry))
                            // Collapsed, the slide fits the room left, centred as without a recording.
                            .frame(maxHeight: transcriptCollapsed ? .infinity : nil)
                        // 6 pt under the slide: the first transcript divider's own top padding
                        // finishes the gap.
                        PaneDivider(
                            axis: .horizontal,
                            isCollapsed: transcriptCollapsed,
                            toggleLabel: transcriptCollapsed ? Text("Show Transcript") : Text("Hide Transcript"),
                            changed: { dragDivider(by: $0, in: geometry) },
                            ended: endDrag,
                            toggle: { storedLayout.isTranscriptCollapsed.toggle() }
                        )
                        .frame(height: ReviewLayout.dividerHeight)
                        .zIndex(1)
                    }
                }
                if model.recording != nil {
                    // Collapsed, the transcript stays (with no height) so its lines, cues and
                    // scroll position are there when it comes back.
                    TranscriptZone(model: model, timeline: timeline)
                        .frame(maxHeight: transcriptCollapsed ? 0 : .infinity)
                        .opacity(transcriptCollapsed ? 0 : 1)
                        .allowsHitTesting(!transcriptCollapsed)
                        .accessibilityHidden(transcriptCollapsed)
                } else {
                    switch model.slides {
                    case .none:
                        // Neither slides nor a recording (or its deck was deleted): the column is a
                        // drop target for this lecture's slides (the screen reloads once they are in).
                        EmptyDropPrompt(systemImage: "rectangle.on.rectangle", line: "Drop this lecture's slides here.", target: .lecture(model.lecture.id))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .notOnThisDevice:
                        // The lecture has slides, on another device (files do not sync): there is
                        // nothing to drop here.
                        ContentUnavailableView {
                            Image(systemName: "rectangle.on.rectangle")
                        } description: {
                            Text("Not on this device")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .shown:
                        // The slide fills the column above.
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { column = $0 }
        }
        // 16 pt to the slide without a rail (no deck, or collapsed: then the rail's edge is 10 of it).
        .padding(.leading, model.deck == nil ? 16 : railCollapsed ? 16 - ReviewLayout.railEdgeWidth : 8)
        .padding(.trailing, 16)
        .padding(.top, 2)
        // The rail and transcript end above the player: it floats over empty space, and nothing
        // scrolls under or below the glass.
        .padding(.bottom, model.player == nil ? 0 : ReviewScreen.playerClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let player = model.player {
                PlayerBar(model: model, player: player, timeline: timeline)
                    .padding(.horizontal, 16)
                    .padding(.bottom, ReviewScreen.playerBottom)
                    // Filing toasts stay above the player, never over Follow, speed or the scrubber.
                    .reservesBottomOverlaySpace(ReviewScreen.playerBottom + PlayerBar.height)
            }
        }
        .background(.background)
        .animation(reduceMotion ? nil : .snappy, value: railCollapsed)
        .animation(reduceMotion ? nil : .snappy, value: transcriptCollapsed)
    }

    /// The column as the slide's height is worked out in: measured to the window's bottom edge.
    private func slideColumn(_ deck: SlideDeck) -> ReviewLayout.Column {
        ReviewLayout.Column(
            size: column,
            below: model.player == nil ? 0 : ReviewScreen.playerClearance,
            aspect: deck.aspectRatio(page: 1)
        )
    }

    private func dragDivider(by translation: CGFloat, in geometry: ReviewLayout.Column) {
        let start = drag?.start ?? storedLayout
        drag = Drag(start: start, current: start.draggingDivider(by: translation, in: geometry))
    }

    private func dragRailEdge(by translation: CGFloat) {
        let start = drag?.start ?? storedLayout
        drag = Drag(start: start, current: start.draggingRailEdge(by: translation, railWidth: SlideRail.width))
    }

    private func endDrag() {
        if let drag { storedLayout = drag.current }
        drag = nil
    }
}

/// The edge between two of the review screen's panes. Nothing is drawn while both panes show
/// (mockup 03 has no line there); a collapsed pane's edge shows a small grabber. The pointer turns
/// into the resize pointer, a drag moves the edge, a double-click collapses the pane or brings it
/// back. The hit area reaches `slop` past either side.
struct PaneDivider: View {
    enum Axis {
        /// Between the slide and the transcript: dragged up and down.
        case horizontal
        /// The rail's edge: dragged left and right.
        case vertical
    }

    static let slop: CGFloat = 2
    /// The grabber a collapsed edge shows.
    static let grabberLength: CGFloat = 36
    static let grabberThickness: CGFloat = 4

    let axis: Axis
    let isCollapsed: Bool
    /// What a double-click does, for VoiceOver ("Hide Transcript").
    let toggleLabel: Text
    /// The drag's translation along the axis since it began (down or right is positive).
    let changed: (CGFloat) -> Void
    let ended: () -> Void
    let toggle: () -> Void

    var body: some View {
        Color.clear
            .overlay {
                if isCollapsed {
                    // A collapsed pane's edge shows where it comes back from (an invisible strip
                    // left the student no way to find it): a small grabber across the edge.
                    Capsule()
                        .fill(.tertiary)
                        .frame(
                            width: axis == .horizontal ? Self.grabberLength : Self.grabberThickness,
                            height: axis == .horizontal ? Self.grabberThickness : Self.grabberLength
                        )
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(pointer)
            #endif
            .gesture(
                // Global: the edge moves with the drag, so its own coordinates would shift under it.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        changed(axis == .horizontal ? value.translation.height : value.translation.width)
                    }
                    .onEnded { _ in ended() }
            )
            .onTapGesture(count: 2, perform: toggle)
            .padding(axis == .horizontal ? .vertical : .horizontal, -Self.slop)
            .accessibilityElement()
            .accessibilityLabel(toggleLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
    }

    #if os(macOS)
    private var pointer: PointerStyle {
        switch axis {
        case .horizontal:
            isCollapsed ? .rowResize(directions: .up) : .rowResize
        case .vertical:
            // The rail has one width: its edge only collapses it or brings it back.
            .columnResize(directions: isCollapsed ? .trailing : .leading)
        }
    }
    #endif
}
