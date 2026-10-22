// swift-tools-version: 6.2
import PackageDescription

// Panes (docs/DESIGN.md 6.4): the Mac main window's side panes, like an editor's. Right of the
// screen's own content, each open pane is a column (or stacked in one) with a 36 pt header
// (title or accessory, Maximize, Close); every divider drags; one toolbar toggle per offered pane
// (⌥⌘1…); Maximize lays a pane over the content area without closing or resizing the others;
// the layout is kept per screen kind. Also the floating panel the agent's small chat lives in
// (moved and resized from every edge and corner by AppKit, its place and size kept).
//
// Platform UI: AppKit is allowed here (NSSplitViewController, one NSHostingController per pane, the
// floating layer). The app is its only client; feature screens speak StudyUI's pane vocabulary
// (`.pane(_:identity:…)`, `\.paneControl`, `\.isLiveResizing`) and never import this package. Mac
// only: every source is `#if os(macOS)`, so an iOS build sees an empty module.
let package = Package(
    name: "Panes",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Panes", targets: ["Panes"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI")
    ],
    targets: [
        .target(
            name: "Panes",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
