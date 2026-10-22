#if os(macOS)
import StudyUI
import SwiftUI

/// View ▸ Show / Hide <pane> (⌥⌘1…⌥⌘9 in toolbar order) and Maximize Pane / Restore Pane (⇧⌘↩)
/// for the key main window's panes (`.paneCommandsTarget(_:)`). ⌘ keys only: they attach only while
/// a main window with panes is key, and work while the student types. Restore Pane is off while
/// the maximized pane has no column to go back to.
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
                .disabled(host.openIDs.isEmpty || (host.maximized != nil && !host.canRestore))
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
