// swift-tools-version: 6.2
import PackageDescription

// M5 workstream B (docs/plan-m5.md §5.2): the tutor (PRD #22). The `tutor` conversation spec
// (Opus 5.5, the read-only lecture tools, Claude Code's WebSearch / WebFetch), the lecture tools
// the mail chat shares, and `TutorChat.send` (the subject's columns, the `<viewing>` / `<course>` /
// `<search>` context blocks). Logic only, no SwiftUI. Never reads mail: the tutor has web tools.
let package = Package(
    name: "Tutor",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Tutor", targets: ["Tutor"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../ClaudeKit"),
        .package(path: "../Agent"),
        .package(path: "../Search")
    ],
    targets: [
        .target(
            name: "Tutor",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "Agent", package: "Agent"),
                .product(name: "Deadlines", package: "Agent"),
                .product(name: "Search", package: "Search")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
