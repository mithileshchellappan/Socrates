import SwiftUI

/// A sidebar row as the mockups draw it (01, 03, 07, 08): a 16 pt glyph column, 8 pt, the title in
/// the 13 pt body face. The app's destination, course-screen and recent-search rows share it, so
/// their glyphs and titles line up.
public struct SidebarRowLabel<Icon: View>: View {
    /// A one-line row's content: with the small sidebar row's insets, the mockups' 29 pt pitch.
    public static var minHeight: CGFloat { 21 }

    private let title: Text
    private let icon: Icon

    public init(_ title: Text, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.icon = icon()
    }

    public init(_ title: String, @ViewBuilder icon: () -> Icon) {
        self.init(Text(verbatim: title), icon: icon)
    }

    public var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 16)
                .accessibilityHidden(true)
            title
                .lineLimit(1)
        }
        .font(.body)
        .frame(minHeight: Self.minHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A sidebar section's title ("Courses", "Recent searches"), lined up with the rows' glyphs above
/// it (mockups 01, 07: 2 pt in from the list's own header inset).
public struct SidebarSectionTitle: View {
    private let title: Text

    public init(_ title: LocalizedStringKey) {
        self.title = Text(title)
    }

    public var body: some View {
        title
            .padding(.leading, 2)
    }
}
