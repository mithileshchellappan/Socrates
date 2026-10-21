import StudyUI
import SwiftUI

/// The lecture review screen (mockup 03): `LectureReviewView` and `ReviewCommands`.
/// See docs/plan-m1.md §5 and Packages/Review/README.md.
public enum ReviewUIModule {
    public static let moduleName = "ReviewUI"
}

// Fetches are stored as `FetchAll` values set in `init` (read through `wrappedValue`), not as
// `@FetchAll var rows: [Row]` declarations: a declaration without an initial value is first
// default-initialized as `FetchAll()`, which observes the whole table on the default database
// (every transcript line of every lecture) before `init` replaces it.

/// How the screen puts itself in its window. `.window` (the app) uses the window toolbar, the
/// inspector column and Liquid Glass. `.snapshot` lays the same toolbar items and inspector out
/// inline and draws glass as material, because off-screen rendering cannot draw window chrome or
/// glass.
enum ReviewChrome: Hashable, Sendable {
    case window
    case snapshot
}

/// The review inspector's tabs: "This slide | Whole lecture" (ma: M5's Tutor tab went to the
/// agent panel).
public enum ReviewInspectorTab: Hashable, Sendable {
    case slide
    case lecture
}

extension EnvironmentValues {
    @Entry var reviewChrome: ReviewChrome = .window
    /// The inspector tab a newly opened review starts on (renders).
    @Entry public var reviewInspectorTab: ReviewInspectorTab = .slide
}

extension View {
    /// A glass capsule: Liquid Glass in the window, material in snapshots. `floating` (the player
    /// over the content) adds a hairline edge and a soft drop shadow, and in dark mode a slightly
    /// lighter fill: plain glass over the flat dark background would not show at all.
    func reviewGlass<S: Shape>(in shape: S, floating: Bool = false) -> some View {
        modifier(ReviewGlass(shape: shape, floating: floating))
    }
}

private struct ReviewGlass<S: Shape>: ViewModifier {
    let shape: S
    let floating: Bool
    @Environment(\.reviewChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch chrome {
        case .window:
            if floating {
                content
                    .background(colorScheme == .dark ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: shape)
                    .glassEffect(.regular, in: shape)
                    .overlay(shape.stroke(.separator, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        case .snapshot:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
    }
}

/// The accent's soft fill (mockup `--accent-soft`): the current line and Follow. Stronger in dark
/// mode, where 12 % barely shows.
enum ReviewTint {
    static func soft(_ colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.24 : 0.12
    }
}

extension View {
    /// A list that ends above the floating player fades out over its last line's height (24 pt),
    /// so a line or thumbnail cut by the edge never shows as a sliver over the player.
    func fadesAbovePlayer(_ isActive: Bool) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                if isActive {
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                }
            }
        }
    }
}

/// Section heading in the inspector ("Your notes"), at the content zoom.
struct SectionLabel: View {
    let title: LocalizedStringKey
    @Environment(\.contentZoom) private var zoom

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.zoomed(.subheadline, zoom, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension Font {
    /// nl (docs/plan-notes-layout.md §11): Review's content type at the content zoom: at 100 % the
    /// text style as before; zoomed, the style's Mac size × `zoom` (the transcript and the
    /// inspector's text; never the toolbar, tabs, rail, stage or player). `\.contentZoom` is 1 on
    /// iOS.
    static func zoomed(_ style: Font.TextStyle, _ zoom: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        guard zoom != 1 else { return .system(style, design: design, weight: weight) }
        return .system(size: macSize(style) * zoom, weight: weight, design: design)
    }

    /// A text style's size on the Mac.
    private static func macSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        default: 10
        }
    }
}
