import StudyCore
import StudyUI
import SwiftUI

/// How the Mail screen puts itself in its window. `.window` (the app) uses the window toolbar and
/// Liquid Glass; `.snapshot` lays the same toolbar items out inline above the content and draws
/// glass as material, because off-screen rendering draws neither
/// window chrome nor glass (as ReviewUI, docs/decisions.md).
enum MailChrome: Hashable, Sendable {
    case window
    case snapshot
}

extension EnvironmentValues {
    @Entry var mailChrome: MailChrome = .window
}

extension MailScope {
    /// The scope's name ("Inbox", "Data Centers", "University", …).
    func title(courses: [Course.ID: Course]) -> String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .course(let id): courses[id]?.name ?? ""
        case .category(let category): category.title
        case .drafts: String(localized: "Drafts")
        case .sent: String(localized: "Sent")
        }
    }

    /// The sidebar glyph (courses show their dot instead).
    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .course: "circle.fill"
        case .category(let category): category.systemImage
        case .drafts: "doc"
        case .sent: "paperplane"
        }
    }
}

extension MailCategory {
    /// "University", "Newsletters", "Personal", "Other".
    var title: String {
        switch self {
        case .university: String(localized: "University")
        case .newsletter: String(localized: "Newsletters")
        case .personal: String(localized: "Personal")
        case .course: String(localized: "Courses")
        default: String(localized: "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .university: "graduationcap"
        case .newsletter: "envelope"
        case .personal: "person"
        default: "tray.2"
        }
    }

    /// The categories a message can be moved to (route menu), after the courses.
    static let routable: [MailCategory] = [.university, .newsletter, .personal, .other]
}

/// A capsule of glass in the window, material in snapshots.
struct MailGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.mailChrome) private var chrome

    func body(content: Content) -> some View {
        switch chrome {
        case .window:
            content.glassEffect(.regular, in: shape)
        case .snapshot:
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }
}

/// The label of a guess the student can change in one click (mockup 05's `.pick`: the route,
/// the lecture a learning platform's file went into): optional leading content, the value in secondary and a
/// small tertiary chevron. Use on a `Menu` with `.quietMenu()`.
struct PickLabel<Leading: View>: View {
    let text: String
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 5) {
            leading
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

extension PickLabel where Leading == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

extension View {
    /// A menu drawn as its own label (no bezel, no system indicator), as the pick menus.
    func quietMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// SF Mono for times (PRD UI rules).
extension Font {
    static func mailMono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

/// Wraps its subviews into lines (recipient tokens).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
