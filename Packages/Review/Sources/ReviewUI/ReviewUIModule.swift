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
/// inline and draws glass as material, because off-screen rendering (StudyUITesting.Snapshot)
/// cannot draw window chrome or glass.
enum ReviewChrome: Hashable, Sendable {
    case window
    case snapshot
}

extension EnvironmentValues {
    @Entry var reviewChrome: ReviewChrome = .window
    /// The inspector tab a newly opened review starts on.
    @Entry var reviewInspectorTab: ReviewModel.InspectorTab = .slide
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
    /// A list that ends above the floating player fades out over its last points, so a line or
    /// thumbnail cut by the edge never shows as a sliver over the player.
    func fadesAbovePlayer(_ isActive: Bool) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                if isActive {
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
            }
        }
    }
}

/// Section heading in the inspector ("Your notes").
struct SectionLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
