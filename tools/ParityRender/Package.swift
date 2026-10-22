// swift-tools-version: 6.2
import PackageDescription

// UI parity without a screen or a running app: renders the app's own main window (sidebar,
// toolbar, screen) and the live lecture window of a parity library copy into off-screen windows
// and writes PNGs, at the mockups' size and names. Nothing is ordered on screen, the process never
// activates (no Dock icon, no focus), and the app bundle is not launched.
//   swift run -j 4 --package-path tools/ParityRender ParityRender [--out DIR] [--only 01-today,03-review]
// `Sources/ParityRender/App` links to the app target's sources (App/), compiled here with the
// app's settings (main-actor default isolation, approachable concurrency) minus its `@main`.
let package = Package(
    name: "ParityRender",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/StudyCore"),
        .package(path: "../../Packages/Capture"),
        .package(path: "../../Packages/Transcription"),
        .package(path: "../../Packages/ClaudeKit"),
        .package(path: "../../Packages/Alignment"),
        .package(path: "../../Packages/Processing"),
        .package(path: "../../Packages/StudyUI"),
        .package(path: "../../Packages/Courses"),
        .package(path: "../../Packages/Filing"),
        .package(path: "../../Packages/Review"),
        .package(path: "../../Packages/Search"),
        .package(path: "../../Packages/Mail"),
        .package(path: "../../Packages/MailIntelligence"),
        .package(path: "../../Packages/MailUI"),
        .package(path: "../../Packages/Agent"),
        .package(path: "../../Packages/CalendarUI"),
        .package(path: "../../Packages/ChatUI"),
        .package(path: "../../Packages/StudyPass"),
        .package(path: "../../Packages/Tutor"),
        .package(path: "../../Packages/Notes"),
        .package(path: "../../Packages/AppAgent"),
        .package(path: "../../Packages/Coach"),
        // M7: AppModel owns the (gated) iCloud sync.
        .package(path: "../../Packages/Sync"),
        // md: the document bank and the Documents screen.
        .package(path: "../../Packages/Documents"),
        // ln: the lecture notes (the notes page, the Lecture menu's Ask… and Highlight).
        .package(path: "../../Packages/StudyPage"),
        // panes: the main window's side panes and the small chat's floating panel.
        .package(path: "../../Packages/Panes")
    ],
    targets: [
        .executableTarget(
            name: "ParityRender",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "CaptureUI", package: "Capture"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "Alignment", package: "Alignment"),
                .product(name: "Processing", package: "Processing"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Courses", package: "Courses"),
                .product(name: "CalendarSync", package: "Courses"),
                .product(name: "CoursesUI", package: "Courses"),
                .product(name: "Filing", package: "Filing"),
                .product(name: "FilingUI", package: "Filing"),
                .product(name: "Review", package: "Review"),
                .product(name: "ReviewUI", package: "Review"),
                .product(name: "Search", package: "Search"),
                .product(name: "SearchUI", package: "Search"),
                .product(name: "Mail", package: "Mail"),
                .product(name: "MailIntelligence", package: "MailIntelligence"),
                .product(name: "MailUI", package: "MailUI"),
                .product(name: "Deadlines", package: "Agent"),
                .product(name: "Agent", package: "Agent"),
                .product(name: "CalendarUI", package: "CalendarUI"),
                .product(name: "ChatUI", package: "ChatUI"),
                .product(name: "StudyPass", package: "StudyPass"),
                .product(name: "Tutor", package: "Tutor"),
                .product(name: "Notes", package: "Notes"),
                .product(name: "NotesUI", package: "Notes"),
                .product(name: "AppAgent", package: "AppAgent"),
                .product(name: "Coach", package: "Coach"),
                .product(name: "CoachUI", package: "Coach"),
                .product(name: "Sync", package: "Sync"),
                .product(name: "Documents", package: "Documents"),
                .product(name: "DocumentsUI", package: "Documents"),
                // mt: the course materials (the library, the shelf and the reader).
                .product(name: "Materials", package: "Documents"),
                .product(name: "MaterialsUI", package: "Documents"),
                .product(name: "StudyPageFormat", package: "StudyPage"),
                .product(name: "StudyPageUI", package: "StudyPage"),
                .product(name: "Panes", package: "Panes")
            ],
            exclude: [
                "App/Info.plist",
                "App/iOS",
                "App/Shared/SocratesApp.swift",
                "App/Shared/Assets.xcassets",
                "App/macOS/Socrates.entitlements"
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
