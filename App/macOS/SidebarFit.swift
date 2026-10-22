import Panes
import SwiftUI

/// The sidebar gives way to the side panes before they do (DESIGN 6.4, room rules): when a pane
/// opens, or a width the window takes on (full screen, a tile, another screen with a larger
/// minimum) leaves too little room, the sidebar hides at once, without animation, so the pane's
/// column shows in the next update; it comes back once the window holds it 40 pt past what the
/// panes want, or when no pane needs room. The window is never made wider.
///
/// - It hides while the sidebar shows, W − screen − sidebar < `requestedNeed` and
///   W − screen ≥ `requestedMinimum` (the panes fit without it). It measures when those change,
///   the window or the screen changes, or a pane waits for it (`awaitingSidebar`: a folded pane
///   opened again changes neither need, so the wait is the request).
/// - It comes back animated, at once with Reduce Motion.
/// - The student's own drag of the window's edge never hides it (the panes give way instead);
///   widening by a drag brings it back.
/// - The student's own toggle (the toolbar's button, View ▸ Show Sidebar ⌃⌘S, dragging it shut)
///   always wins, and a practice round or exam owns the sidebar while it runs.
struct SidebarFit: View {
    @Binding var columns: NavigationSplitViewVisibility
    let sidebarWidth: CGFloat
    /// The screen on display's declared minimum (`WindowColumns.detailMin(for:)`).
    let screenMin: CGFloat
    /// What the open panes want and need (read here, so a change re-renders only this view).
    let panes: PaneHostModel
    let isPaused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Measured here, so a window resize re-renders only this view.
    @State private var windowWidth: CGFloat = 0
    /// The sidebar is hidden by this, not by the student.
    @State private var hidSidebar = false
    /// What this view last wrote (its own changes are not the student's).
    @State private var wrote: NavigationSplitViewVisibility?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { windowWidth = $0 }
            .onChange(of: panes.requestedNeed) { fit() }
            .onChange(of: panes.requestedMinimum) { fit() }
            .onChange(of: panes.awaitingSidebar) { _, waiting in
                if waiting != nil { fit() }
            }
            .onChange(of: windowWidth) { fit() }
            // Another screen (Mail needs more than 480): the sidebar makes room or comes back.
            .onChange(of: screenMin) { fit() }
            .onChange(of: columns) { _, visibility in
                if visibility != wrote { hidSidebar = false }
                wrote = nil
            }
    }

    private func fit() {
        guard !isPaused, windowWidth > 0 else { return }
        let need = panes.requestedNeed
        let besideScreen = windowWidth - screenMin
        let besideSidebar = besideScreen - (sidebarWidth + WindowColumns.sidebarInset)
        if columns != .detailOnly {
            // Not while the student drags the window's edge (or a pane's): the panes give way.
            guard !panes.isLiveResizing, need > 0, besideSidebar < need, besideScreen >= panes.requestedMinimum else { return }
            hidSidebar = true
            write(.detailOnly, animated: false)
        } else if hidSidebar, need == 0 || besideSidebar - WindowColumns.sidebarReturn >= need {
            hidSidebar = false
            write(.all, animated: !reduceMotion)
        }
    }

    private func write(_ visibility: NavigationSplitViewVisibility, animated: Bool) {
        guard columns != visibility else { return }
        wrote = visibility
        var transaction = Transaction(animation: animated ? .default : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { columns = visibility }
    }
}
