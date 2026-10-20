// swift-tools-version: 6.2
import PackageDescription

// ln (docs/plan-lecture-notes.md, docs/plan-learn-more.md §2–3): Claude's study text, drawn
// natively. One parser for the agent panel's answers and the lecture notes.
//   StudyPageFormat  no UI: the Markdown block parser (moved here from ChatUI, with GitHub alert
//                    callouts), inline runs with inline math, `ChartSpec` with its own expression
//                    evaluator, the Mermaid subset parsed and laid out in pure Swift, `CodeLexer`,
//                    text-quote anchors for the student's marks.
//   StudyPageUI      platform UI: the block views (SwiftMath formulas, Swift Charts, diagrams in a
//                    Canvas, code, tables, callouts, slides with the student's ink, professor
//                    quotes from their rows, the student's notes as Notes draws them), the figure
//                    checker, and `LectureNotesView`: one read-only TextKit 2 document with
//                    select-and-ask, kept answers and highlights.
let package = Package(
    name: "StudyPage",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "StudyPageFormat", targets: ["StudyPageFormat"]),
        .library(name: "StudyPageUI", targets: ["StudyPageUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        // Slide figures draw pages with `SlideDeck` / `SlideImageView`.
        .package(path: "../Capture"),
        // The student's notes inside the lecture notes are drawn as Notes draws them, and the
        // document reuses NotesUI's TextKit 2 attachment machinery.
        .package(path: "../Notes"),
        // Formulas (MIT; its math fonts under the GUST and SIL OFL licences, MIT for the bundle's
        // tables: tools/oss/notices.tsv).
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")
    ],
    targets: [
        .target(
            name: "StudyPageFormat",
            dependencies: [.product(name: "StudyCore", package: "StudyCore")]
        ),
        .target(
            name: "StudyPageUI",
            dependencies: [
                "StudyPageFormat",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "CaptureUI", package: "Capture"),
                .product(name: "Notes", package: "Notes"),
                .product(name: "NotesUI", package: "Notes"),
                .product(name: "SwiftMath", package: "SwiftMath")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
