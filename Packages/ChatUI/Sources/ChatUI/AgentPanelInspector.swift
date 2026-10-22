#if os(iOS)
import StudyCore
import StudyUI
import SwiftUI

/// The iPad's chat, as before the Mac's panes: compact, a panel floating over the window's
/// bottom-trailing corner (moved by its title row, the place kept per window); expanded, the
/// window's full-height trailing inspector column (resizable, the width kept), and
/// `\.agentPanelExpanded` for the screens whose inspector yields to it.
struct AgentPanelInspector: ViewModifier {
    let model: AgentPanelModel
    let isAvailable: Bool

    /// The compact panel's place: its offset from the bottom-trailing corner, "x,y".
    @SceneStorage("agent.panel.position") private var position = ""
    /// The expanded column's width as the student last dragged it.
    @AppStorage("agent.panel.width") private var width = AgentPanelMetrics.idealWidth

    func body(content: Content) -> some View {
        let model = model
        let expanded = isAvailable && model.mode == .expanded
        let ideal = min(max(CGFloat(width), AgentPanelMetrics.minWidth), AgentPanelMetrics.maxWidth)
        content
            .environment(\.agentPanelExpanded, expanded)
            .overlay {
                if isAvailable, model.mode == .compact {
                    CompactPanelHost(model: model, position: $position)
                        .transition(.opacity)
                }
            }
            .inspector(isPresented: Binding(
                get: { expanded },
                set: { isShown in if !isShown, model.mode == .expanded { model.close() } }
            )) {
                // SwiftUI keeps a hidden inspector's content alive: only while shown, so its
                // composer never takes the caret from the compact one.
                Group {
                    if expanded {
                        ExpandedAgentPanel(model: model, width: $width)
                    } else {
                        Color.clear
                    }
                }
                .inspectorColumnWidth(min: AgentPanelMetrics.minWidth, ideal: ideal, max: AgentPanelMetrics.maxWidth)
            }
    }
}

/// The compact panel's layer over the window: it measures the window itself, so a window resize
/// re-renders the panel's placement only.
private struct CompactPanelHost: View {
    let model: AgentPanelModel
    @Binding var position: String

    @State private var windowSize: CGSize = .zero

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            .overlay(alignment: .bottomTrailing) {
                CompactAgentPanel(model: model, position: $position, windowSize: windowSize)
            }
    }
}

/// The floating panel: the opaque surface, radius 14, a soft panel shadow, 336 wide, as tall as
/// its content up to half the window; moved by dragging its title row, kept inside the window.
/// A drag moves it by an offset alone (`PanelMove`, read only by `PanelPlacement`); the place is
/// stored once, when the drag ends.
private struct CompactAgentPanel: View {
    let model: AgentPanelModel
    @Binding var position: String
    let windowSize: CGSize

    @State private var move = PanelMove()
    @State private var size = CGSize(width: AgentPanelMetrics.compactWidth, height: 90)
    /// The height the window's toasts keep clear of.
    @State private var reserved: CGFloat = 90
    @State private var isDropTargeted = false

    var body: some View {
        let bounds = PanelBounds(windowSize: windowSize, panelSize: size)
        let stored = bounds.clamp(Self.parse(position))
        let move = move
        let drag = PanelDrag(
            changed: { move.translation = $0 },
            ended: { translation in
                position = Self.format(bounds.clamp(stored, adding: translation))
                move.translation = .zero
            },
            cancelled: { move.translation = .zero }
        )
        AgentPanelView(
            style: .compact, model: model, maxHeight: (windowSize.height > 0 ? windowSize.height : 740) / 2, header: .inline, drag: drag
        )
        .modifier(CompactPanelChrome(isDropTargeted: isDropTargeted))
        .agentFileDrop(model: model, isTargeted: $isDropTargeted)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            size = newSize
            // The toasts' room follows a streaming answer in steps of a line or more, and
            // exactly once it ends.
            if abs(newSize.height - reserved) >= 17 || !model.isRunning { reserved = newSize.height }
        }
        .onChange(of: model.isRunning) { _, running in
            if !running { reserved = size.height }
        }
        // The stored place, not the drag: the toasts' room changes once, when the drag ends.
        .reservesPanelSpace(reserved + AgentPanelMetrics.margin + 8, isActive: stored.height < 1)
        .modifier(PanelPlacement(move: move, stored: stored, bounds: bounds))
        .padding(.trailing, AgentPanelMetrics.margin)
        .padding(.bottom, AgentPanelMetrics.margin)
        .transition(.opacity)
    }

    static func parse(_ text: String) -> CGSize {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return .zero }
        return CGSize(width: parts[0], height: parts[1])
    }

    static func format(_ offset: CGSize) -> String {
        "\(Int(offset.width.rounded())),\(Int(offset.height.rounded()))"
    }
}

/// The compact panel's drag in flight (window points; right and down positive): written by the
/// title row's gesture, read only by `PanelPlacement`.
@MainActor
@Observable
private final class PanelMove {
    var translation: CGSize = .zero
}

/// Where the compact panel may go: its offset from the window's bottom-trailing corner, inside
/// the window under the toolbar, on whole points (the drag and the stored place agree, so the
/// panel does not shift when the drag ends).
private struct PanelBounds: Equatable {
    var maxX: CGFloat
    var maxY: CGFloat

    init(windowSize: CGSize, panelSize: CGSize) {
        maxX = max(0, (windowSize.width - panelSize.width - 2 * AgentPanelMetrics.margin).rounded(.down))
        maxY = max(0, (windowSize.height - panelSize.height - 2 * AgentPanelMetrics.margin - AgentPanelMetrics.toolbarHeight).rounded(.down))
    }

    /// An offset plus a drag (a drag right or down moves toward the corner), kept inside.
    func clamp(_ offset: CGSize, adding translation: CGSize = .zero) -> CGSize {
        CGSize(
            width: min(max(0, (offset.width - translation.width).rounded()), maxX),
            height: min(max(0, (offset.height - translation.height).rounded()), maxY)
        )
    }
}

/// Places the compact panel: its stored offset plus the drag in flight. Only this modifier reads
/// the drag, so a drag re-evaluates nothing inside the panel.
private struct PanelPlacement: ViewModifier {
    let move: PanelMove
    let stored: CGSize
    let bounds: PanelBounds

    func body(content: Content) -> some View {
        let offset = bounds.clamp(stored, adding: move.translation)
        content.offset(x: -offset.width, y: -offset.height)
    }
}

/// The full-height trailing column: the chat at the inspector's place, its title row level with
/// the toolbar (toolbar items over the column while shown), resizable by its leading edge
/// (300–560, the width the student dragged kept).
private struct ExpandedAgentPanel: View {
    let model: AgentPanelModel
    @Binding var width: Double

    @State private var isDropTargeted = false
    /// The width the student is dragging the column to (stored in `width` once it rests).
    @State private var dragged: Double?

    var body: some View {
        AgentPanelView(style: .expanded, model: model, maxHeight: .infinity, header: .toolbar)
            // No minimum and a fixed ideal of its own: a long answer's one-line width (a table, a
            // code line) never becomes the column's, so `inspectorColumnWidth` alone sizes it.
            .frame(minWidth: 0, idealWidth: CGFloat(AgentPanelMetrics.idealWidth), maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { ExpandedPanelBackground() }
            .overlay {
                if isDropTargeted {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).ignoresSafeArea()
                }
            }
            .agentFileDrop(model: model, isTargeted: $isDropTargeted)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
                let rounded = Double(newWidth.rounded())
                if rounded >= Double(AgentPanelMetrics.minWidth), abs(rounded - width) >= 1 { dragged = rounded }
            }
            .task(id: dragged) {
                // Stored once the width rests (300 ms), not on every frame of a drag.
                guard let dragged else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, abs(dragged - width) >= 1 else { return }
                width = dragged
            }
    }
}
#endif
