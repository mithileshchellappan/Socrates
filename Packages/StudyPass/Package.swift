// swift-tools-version: 6.2
import PackageDescription

// Workstream A (M4, docs/plan-m4.md §3–4): the AI study pass. Per lecture, in the background, one
// unit at a time through the student's Claude Code: transcript corrections (patches), slide and
// lecture summaries, said in class but not on the slides, exam hints and highlights (the
// professor's exact words), topics, further reading (Claude Code's WebSearch/WebFetch only,
// every source checked by the app's own fetch). Writes `annotation`, `study_unit` and
// `transcript_segment.patches` rows; never reads mail tables, never links MailIntelligence.
let package = Package(
    name: "StudyPass",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "StudyPass", targets: ["StudyPass"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../ClaudeKit"),
        // `Deadlines` only: `TranscriptQuote` (locating the professor's exact words and their
        // time) and `TextFolding`.
        .package(path: "../Agent"),
        // `SlidePageRenderer` (figure slides as images for the read calls), deck files.
        .package(path: "../Capture")
    ],
    targets: [
        .target(
            name: "StudyPass",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "Deadlines", package: "Agent"),
                .product(name: "Capture", package: "Capture")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
