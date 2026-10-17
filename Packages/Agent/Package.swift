// swift-tools-version: 6.2
import PackageDescription

// Workstream A (M3, docs/plan-m3.md §3): the deadline & exercise memory and the agent.
//
// - `Deadlines` (StudyCore only): `DeadlineMemory`, the one place that adds, merges, updates,
//   completes, dismisses and undoes tracked items from any source (mail, transcript, chat, the
//   student), the cross-source matcher, the DE/EN date parser (`DateMentions`, moved here from
//   MailIntelligence) and the composer's local parse. MailIntelligence depends on it.
// - `Agent` (+ ClaudeKit): the tool runtime (conversation kinds with fixed tool sets, append-only
//   turns, streaming, staged proposals), the deadline tools, transcript extraction and the
//   composer's agent path.
//
// Never depends on MailIntelligence or Mail (MailIntelligence depends on `Deadlines`; a package
// cycle is not allowed), and nothing here can send mail.
let package = Package(
    name: "Agent",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Deadlines", targets: ["Deadlines"]),
        .library(name: "Agent", targets: ["Agent"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../ClaudeKit"),
        // Already in the graph through SQLiteData (same pin as Search and MailIntelligence); used
        // directly for `DatabaseRegionObservation` (transcript extraction follows new transcripts).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0"),
        // Tests only: `DemoLibrary` (mockups 01 and 06 as rows).
        .package(path: "../StudyUI")
    ],
    targets: [
        .target(
            name: "Deadlines",
            dependencies: [.product(name: "StudyCore", package: "StudyCore")]
        ),
        .target(
            name: "Agent",
            dependencies: [
                "Deadlines",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
