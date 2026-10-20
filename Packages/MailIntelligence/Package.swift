// swift-tools-version: 6.2
import PackageDescription

// Workstream B (M2, M3.5): what the app understands from mail. Routing to courses (rules, then
// Haiku; corrections become rules), triage (deadlines / announcements / room changes /
// cancellations / tasks into tracked items with verified quotes, and whether a mail needs a
// reply), digest data, Opus reply drafts (text only), mail search chunks, the read-only mail tools
// and the mail chat's conversation spec.
//
// Deliberately no dependency on `Mail`: nothing here can send mail or touch the server.
let package = Package(
    name: "MailIntelligence",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MailIntelligence", targets: ["MailIntelligence"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../ClaudeKit"),
        // M3: `Deadlines` (the deadline memory every tracked item write goes through, `DateMentions`
        // and the text folding helpers). M3.5: `Agent` (the mail chat's conversation spec: tools,
        // the deadline tool kit). `Agent` never depends back on MailIntelligence.
        .package(path: "../Agent"),
        // `Lemmatizer` only (public, frozen in M2): mail chunks get the same `lemma_text` as
        // transcripts, so the search engine matches them alike.
        .package(path: "../Search"),
        // Already in the graph through SQLiteData (same pin as Search); used directly for raw
        // FTS5 SQL and `DatabaseRegionObservation` (SQLiteData re-exports only a few GRDB types).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0")
    ],
    targets: [
        .target(
            name: "MailIntelligence",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "Deadlines", package: "Agent"),
                .product(name: "Agent", package: "Agent"),
                .product(name: "Search", package: "Search"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
