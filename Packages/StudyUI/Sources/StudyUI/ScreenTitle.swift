import SwiftUI

extension View {
    /// A main-window screen's title as the mockups draw it (01, 03, 07, 08): on the Mac a 15 pt
    /// semibold title over an 11 pt secondary subtitle at the leading end of the toolbar, without
    /// glass, after any leading controls (the sidebar toggle). The navigation title and subtitle
    /// stay set for the Window menu, the window title and accessibility. iOS shows its own title.
    public func screenTitle(_ title: String, subtitle: String? = nil) -> some View {
        modifier(ScreenTitleModifier(title: title, subtitle: subtitle))
    }
}

private struct ScreenTitleModifier: ViewModifier {
    let title: String
    let subtitle: String?

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ScreenTitleView(title: title, subtitle: subtitle)
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

