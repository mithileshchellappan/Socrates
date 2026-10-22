#if os(macOS)
import StudyUI
import SwiftUI

/// What the floating panel's content sees: the content itself, the host's environment, the
/// stored frame, the mover, whether it is being resized, and whether it hugs its content (up to
/// `cap`, half the window). Written by the panel's AppKit view, read by its SwiftUI root.
@MainActor
@Observable
final class FloatingPanelState {
    /// The content while the panel is presented (nil once it has faded out).
    var content: AnyView?
    var environment = EnvironmentValues()
    var frame = FloatingPanelFrame.initial
    var isLiveResizing = false
    /// As tall as its content (until the student resizes it).
    var hugs = true
    /// The tallest a hugging panel gets: half the window's content area.
    var cap: CGFloat = 370

    @ObservationIgnored var mover = FloatingPanelMover(changed: { _ in }, ended: {})
    /// The content's height while it hugs (whole points), for SwiftUI to size the panel.
    @ObservationIgnored var onHug: (CGFloat) -> Void = { _ in }
}
#endif
