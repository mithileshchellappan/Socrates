# Panes

The Mac main window's side panes (docs/DESIGN.md 6.4) and the floating panel the agent's small chat lives in. Platform UI: AppKit is allowed here and nowhere else in the milestone. The app is the only client. Feature screens never import this package: they use StudyUI's pane vocabulary (`Packages/StudyUI/Sources/StudyUI/Panes.swift`).

## Shape

- **`PaneHost`** (SwiftUI) wraps the screen's navigation stack in the detail column of the window's `NavigationSplitView`. The screen stays in the window's own SwiftUI tree, so its toolbar items, title, focus, commands and scene storage work as they did. Right of it, an `NSSplitViewController` lays out the open panes. Each column is a split item. A column with stacked panes is a nested vertical split. Each pane lives in its own `NSHostingController` with `sizingOptions = []` and `sceneBridgingOptions = []`, under a 36 pt AppKit header with the title or accessory, ⤢ / ⤡ and ✕.
- **`PaneHostModel`** holds one window's panes: offered specs, open panes, the maximized pane, the room the window must keep (`placedNeed`, `requestedNeed`), the live-resize flag, and the pane whose text has the keyboard (`typingPane`). Requests are `open`, `close`, `toggle` and `toggleMaximized`. `control` exposes them to screens as `\.paneControl`.
- **`PaneSpec`** describes a pane: id, title, glyph, widths 260–560, whether it opens by default, whether its open state is per window (the agent), and whether the header shows the title or the accessory. The app keeps the table of which screen kind offers which panes.
- **`PaneLayout`** is Codable and kept per screen kind under `Socrates.panes.<kind>`. It stores the columns (stacks of panes, open or closed), their widths and stack fractions, the open panes and the maximized one. Window-wide open panes are stored under `Socrates.panes.windowOpen`. `PaneLayoutStore` reads and writes both.
- **`PaneToolbarToggles`** is one glass group with one toggle per offered pane, the agent last. It is the last of the app's trailing items.
- **`PaneCommands`** gives View ▸ Show / Hide each pane (⌥⌘1…⌥⌘9 in toolbar order) and Maximize Pane / Restore Pane (⇧⌘↩). Commands find the window's model through `.paneCommandsTarget(_:)`.
- **`.floatingPanel(isPresented:frame:content:)`** is an AppKit view of the panel's size that SwiftUI places over the content area. A drag on the content's title row (`\.floatingPanelMover`) moves only its layer, with no layout and no body. When the drag ends, the frame is written once and SwiftUI takes the new place. Its edges and corners resize it. Outside its rectangle the window is untouched.
- Off-screen renders (tools/ParityRender) draw the real window, panes included: its composite draws every hosting view in tree order.

## Rules

1. Pane content reads the screen's state only through `@Observable` objects its offer captures. Values, bindings, `@FocusState`, the screen's environment and preferences do not cross hosting views. A pane root gets the host's environment, plus `\.isLiveResizing` and `\.paneIsMaximized`.
2. A pane's content closure is called again only when its offer's identity changes.
3. Layouts are written only when a student's action ends: a divider or header drag, a toggle, ✕, maximize. A width that a narrow window imposed is never written.
4. Columns never move by SwiftUI animation. Showing or hiding a pane changes the layout once and animates the pane's layer. Maximize is a 0.2 s cross-fade of layers. With Reduce Motion, all of it happens in one frame.
5. Nothing closes another pane, and the window never grows. When room runs out, the sidebar hides first (the app's sidebar fit reads `requestedNeed`). Then the widest open pane gives way toward its minimum. If that is still not enough, a pane being opened opens maximized.
6. No tests (the project's rule). Verification is `swift build --package-path Packages/Panes -j 4`, the app build, and renders.
