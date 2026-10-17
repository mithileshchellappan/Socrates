import SwiftUI

/// The quiet grey of the mockups' `--fill` (120, 120, 128 at 10 % light, 20 % dark): the
/// selected hits' block and the filter's track. Neutral, so match highlights stay yellow and the
/// accent stays for the one filled button.
struct QuietFill: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255)
            .opacity(environment.colorScheme == .dark ? 0.20 : 0.10)
            .resolve(in: environment)
    }
}

/// The highlighter yellow of the mockups (`--ink-hl`: 45 % light, 40 % dark).
struct MatchInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        Color(red: 1, green: 214 / 255, blue: 10 / 255)
            .opacity(environment.colorScheme == .dark ? 0.40 : 0.45)
            .resolve(in: environment)
    }
}

/// The search screen's measures (mockup 07).
enum SearchMetrics {
    /// Results column: from 18 pt after the sidebar to the toolbar's trailing inset (14 pt), so
    /// the scope menu, time chips and thumbnails end under the search field's trailing edge.
    static let margin: CGFloat = 18
    static let trailingMargin: CGFloat = 14
    /// Between the filters and the groups, and between groups.
    static let groupSpacing: CGFloat = 14
    /// A hit's padding inside its (selection) block.
    static let hitPadding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    static let selectionRadius: CGFloat = 10
}
