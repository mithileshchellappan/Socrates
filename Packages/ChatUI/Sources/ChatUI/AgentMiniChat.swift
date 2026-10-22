#if os(macOS)
import StudyCore
import StudyUI
import SwiftUI

/// The small chat, for the Mac app's floating panel (presented while `model.isMiniShown`): its
/// 38 pt title row (the history menu, ⤢ Expand Chat, ✕ Hide Chat), the conversation, the task line
/// and the composer. Dragging the row's free part moves the panel (`\.floatingPanelMover`, the
/// grab pointer). It is as tall as its content (the panel caps it at half the window) until the
/// student resizes the panel, then (from the resize's first frame) it fills it. The panel draws
/// its surface, ring, shadow and width. Files dropped on it are attached; while it sits in its
/// corner the window's toasts stay above it.
///
///     .floatingPanel(isPresented: model.isMiniShown, frame: $frame) { AgentMiniChat(model: model) }
public struct AgentMiniChat: View {
    private let model: AgentPanelModel

    @Environment(\.floatingPanelMover) private var mover
    @Environment(\.floatingPanelFrame) private var frame
    /// The student is resizing the panel (it is set for the panel's own resize only).
    @Environment(\.isLiveResizing) private var isResizing
    @State private var isDropTargeted = false
    /// The chat's height as laid out.
    @State private var height: CGFloat = 90
    /// The height the window's toasts keep clear of (kept while the panel is resized: it changes
    /// once, when the resize ends).
    @State private var reserved: CGFloat = 90

    public init(model: AgentPanelModel) {
        self.model = model
    }

    public var body: some View {
        AgentPanelView(
            style: .compact, model: model, maxHeight: .infinity, header: .inline, drag: mover.map(PanelDrag.init),
            fillsHeight: frame?.height != nil || isResizing
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: AgentPanelMetrics.radius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .agentFileDrop(model: model, isTargeted: $isDropTargeted)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [isResizing] newHeight in
            height = newHeight
            // The toasts' room follows a streaming answer in steps of a line or more, and exactly
            // once it ends; a resize moves it once, at its end.
            guard !isResizing else { return }
            if abs(newHeight - reserved) >= 17 || !model.isRunning { reserved = newHeight }
        }
        .onChange(of: model.isRunning) { _, running in
            if !running { reserved = height }
        }
        .onChange(of: isResizing) { _, resizing in
            if !resizing { reserved = height }
        }
        // The stored place, not a drag in flight: the toasts' room changes once, when it ends.
        .reservesPanelSpace(reserved + AgentPanelMetrics.margin + 8, isActive: frame?.sitsInCorner ?? false)
    }
}
#endif
