// swift-tools-version: 6.2
import PackageDescription

// UI parity without a screen or a running app: renders the app's own main window (sidebar,
// toolbar, screen) and the live lecture window of a parity library copy into off-screen windows
// and writes PNGs, at the mockups' size and names. Nothing is ordered on screen, the process never
// activates (no Dock icon, no focus), and the app bundle is not launched.
//   tools/parity/render [--out DIR] [--only 01-today,03-review] [--appearance light|dark|both]
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
        .package(path: "../../Packages/Tutor")
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
                .product(name: "Tutor", package: "Tutor")
            ],
            exclude: [
                "App/Info.plist",
                "App/iOS",
                "App/Shared/StudyPortalApp.swift",
                "App/Shared/Assets.xcassets",
                "App/macOS/StudyPortal.entitlements"
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
