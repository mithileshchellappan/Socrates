#if os(macOS)
import SwiftUI

/// The pane host's environment (the window's values at its place), captured on every update of
/// the strip, for the panes' own hosting views: they are not in the window's view graph, so they
/// would see none of it otherwise. Only the pane roots read it.
@MainActor
@Observable
final class PaneEnvironment {
    var values = EnvironmentValues()
}
#endif
