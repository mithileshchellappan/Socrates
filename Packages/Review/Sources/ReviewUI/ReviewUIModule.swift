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
    /// The floating capsule: Liquid Glass in the window, material in snapshots.
    func reviewGlass<S: Shape>(in shape: S) -> some View {
        modifier(ReviewGlass(shape: shape))
    }
}

private struct ReviewGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.reviewChrome) private var chrome

    func body(content: Content) -> some View {
        switch chrome {
        case .window:
            content.glassEffect(.regular, in: shape)
        case .snapshot:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
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
