import Panes
import SwiftUI

/// Puts the pane toggles at the toolbar's trailing end, after the screen's own groups (DESIGN 6.3,
/// mockup 40): toolbar items declared under the screen in the view tree follow the screen's, while
/// the window's own trailing items (applied around the screen) come before them. Draws nothing.
struct PaneToggleBar: View {
    let panes: PaneHostModel

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .toolbar { PaneToolbarToggles(model: panes) }
    }
}
