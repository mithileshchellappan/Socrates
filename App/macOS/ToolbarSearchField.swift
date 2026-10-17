import SwiftUI

/// The window's search field as a toolbar item of its own (mockups 01, 07, 10): a small tertiary
/// magnifier and the prompt in a 240 pt glass capsule, placed before Record and More.
/// `.searchable` cannot be ordered among the other items of a `NavigationSplitView` toolbar on
/// macOS 26 (decisions.md), and an `NSSearchField` there draws the system's larger magnifier, so
/// the main window draws the field itself. ↩ runs `submit`, Esc clears it (then leaves it).
struct ToolbarSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    /// The mockups' capsule.
    static let width: CGFloat = 240

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            // The prompt drawn here: a field's own placeholder ignores its style on the Mac.
            TextField("", text: $text)
            .accessibilityLabel(Text(prompt))
            .textFieldStyle(.plain)
            .font(.body)
            .focused(focused)
            .onSubmit(submit)
            .onExitCommand {
                if text.isEmpty {
                    focused.wrappedValue = false
                } else {
                    text = ""
                }
            }
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .frame(width: Self.width)
    }
}
