// swift-tools-version: 6.2
import PackageDescription

// Workstream A of milestone ma (docs/plan-agent.md §5.1): the one app agent. Logic only, no
// SwiftUI. The `app` conversation (every domain's tools, a short catalog and the screen's context
// as blocks, attachments as content blocks), sub-agent tasks (`task` conversations, ≤ 2 at once
// in the background), the batched Haiku triage of new facts with Opus escalation, the activity
// log with Undo (`ChangeLog`), and the agent's reminders (macOS notifications).
//
// Nothing here can send mail (no dependency on `Mail`), write calendars other than the app's own
// (the calendar mirror does that from the rows), or delete the student's notes or recordings.
let package = Package(
    name: "AppAgent",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AppAgent", targets: ["AppAgent"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../ClaudeKit"),
        .package(path: "../Agent"),
        .package(path: "../MailIntelligence"),
        .package(path: "../Tutor"),
        .package(path: "../Search"),
        // `Courses` only (`CourseSchedule`'s in-transaction session edits and replanning).
        .package(path: "../Courses"),
        .package(path: "../StudyPass"),
        // Already in the graph through SQLiteData (same pin as Agent); used directly for raw
        // aggregate reads (the catalog) and `DatabaseRegionObservation` (the task queue).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0")
    ],
    targets: [
        .target(
            name: "AppAgent",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "Agent", package: "Agent"),
                .product(name: "Deadlines", package: "Agent"),
                .product(name: "MailIntelligence", package: "MailIntelligence"),
                .product(name: "Tutor", package: "Tutor"),
                .product(name: "Search", package: "Search"),
                .product(name: "Courses", package: "Courses"),
                .product(name: "StudyPass", package: "StudyPass"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
