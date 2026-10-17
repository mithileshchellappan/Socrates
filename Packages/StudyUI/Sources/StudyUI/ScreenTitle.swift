import SwiftUI

extension View {
    /// A main-window screen's title as the mockups draw it (01, 03, 07, 08): on the Mac a 15 pt
    /// semibold title over an 11 pt secondary subtitle at the leading end of the toolbar, without
    /// glass, after any leading controls (the sidebar toggle). The navigation title and subtitle
    /// stay set for the Window menu, the window title and accessibility. iOS shows its own title.
    /// `leadingInset` moves the title right on a screen where it is the toolbar's first item
    /// (`ScreenTitleInset.firstItem`).
    public func screenTitle(_ title: String, subtitle: String? = nil, leadingInset: CGFloat = 0) -> some View {
        modifier(ScreenTitleModifier(title: title, subtitle: subtitle, leadingInset: leadingInset))
    }
}

/// Where a screen title starts.
public enum ScreenTitleInset {
    /// The macOS 26 toolbar starts its first item 9 pt into the content column; the mockups' title
    /// starts 18 pt in, in line with the content's margin below it (07).
    public static let firstItem: CGFloat = 9
}

private struct ScreenTitleModifier: ViewModifier {
    let title: String
    let subtitle: String?
    let leadingInset: CGFloat

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ScreenTitleView(title: title, subtitle: subtitle)
                        .padding(.leading, leadingInset)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        #else
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
        #endif
    }
}

/// "Today" over "Friday, 16 October 2026 · no classes".
struct ScreenTitleView: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

