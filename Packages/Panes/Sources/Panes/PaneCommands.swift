#if os(macOS)
import StudyUI
import SwiftUI

/// The toggles at the toolbar's trailing end: one glass group, one button per offered pane in
/// toolbar order (the agent last), lit (accent soft, accent glyph) while its pane is open; help
/// "Notes ⌥⌘1". Reads only which panes are offered and open, so no drag re-renders the toolbar.
/// The app puts it last among its trailing items.
public struct PaneToolbarToggles: ToolbarContent {
    private let model: PaneHostModel

    public init(model: PaneHostModel) {
        self.model = model
    }

    public var body: some ToolbarContent {
        if !model.specs.isEmpty {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(model.specs) { spec in
                    PaneToggle(model: model, spec: spec)
                }
            }
        }
    }
}

/// One pane's toggle (contracts stub: workstream A draws the lit state as DESIGN 6.3's toggles).
private struct PaneToggle: View {
    let model: PaneHostModel
    let spec: PaneSpec

    var body: some View {
        let isOpen = model.isOpen(spec.id)
        Button {
            model.toggle(spec.id)
        } label: {
            Label(spec.menuTitle, systemImage: spec.systemImage)
                .labelStyle(.iconOnly)
        }
        .foregroundStyle(isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .help(help)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }

    private var help: String {
        guard let number = model.shortcutNumber(of: spec.id) else { return spec.menuTitle }
        return "\(spec.menuTitle) ⌥⌘\(number)"
    }
}

/// View ▸ Show / Hide <pane> (⌥⌘1…⌥⌘9 in toolbar order) and Maximize Pane / Restore Pane (⇧⌘↩)
/// for the key main window's panes (`.paneCommandsTarget(_:)`). ⌘ keys only: they attach only while
/// a main window with panes is key, and work while the student types.
public struct PaneCommands: Commands {
    @FocusedValue(\.paneHost) private var host

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            if let host {
                ForEach(host.specs) { spec in
                    Button(host.isOpen(spec.id) ? "Hide \(spec.menuTitle)" : "Show \(spec.menuTitle)") {
                        host.toggle(spec.id)
                    }
                    .keyboardShortcut(Self.shortcut(host.shortcutNumber(of: spec.id)))
                }
                Button(host.maximized == nil ? "Maximize Pane" : "Restore Pane") {
                    host.toggleMaximized()
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(host.openIDs.isEmpty)
            }
        }
    }

    private static func shortcut(_ number: Int?) -> KeyboardShortcut? {
        guard let number, let digit = String(number).first else { return nil }
        return KeyboardShortcut(KeyEquivalent(digit), modifiers: [.command, .option])
    }
}

extension FocusedValues {
    /// The key main window's panes (`PaneCommands`).
    @Entry public var paneHost: PaneHostModel?
}

extension View {
    /// Publishes the window's panes to `PaneCommands` (apply once, at the window's root).
    public func paneCommandsTarget(_ model: PaneHostModel) -> some View {
        focusedSceneValue(\.paneHost, model)
    }
}
#endif
