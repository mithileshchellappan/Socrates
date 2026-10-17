// swift-tools-version: 6.2
import PackageDescription

// Workstream B (M2): what the app understands from mail. Routing to courses (rules, then Haiku;
// corrections become rules), extraction of deadlines / announcements / room changes /
// cancellations into tracked items with verified quotes, digest data, Opus reply drafts (text
// only), mail search chunks and the read-only mail tools for Q&A.
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
        // `Lemmatizer` only (public, frozen in M2): mail chunks get the same `lemma_text` as
        // transcripts, so the search engine matches them alike.
        .package(path: "../Search")
    ],
    targets: [
        .target(
            name: "MailIntelligence",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "Search", package: "Search")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
