import Review
import SwiftUI

/// The notes' background: the system's as is in light mode; in dark mode lifted a little above
/// the content (which it otherwise matches) so it reads as a panel of its own. Snapshots have no
/// side column, so they draw the secondary background.
struct ReviewNotesBackground: View {
    @Environment(\.reviewChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch chrome {
        case .window:
            if colorScheme == .dark {
                Rectangle().fill(.white.opacity(0.025)).ignoresSafeArea()
            }
        case .snapshot:
            Rectangle().fill(.background.secondary)
        }
    }
}
