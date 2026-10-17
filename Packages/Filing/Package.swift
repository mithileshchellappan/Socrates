// swift-tools-version: 6.2
import PackageDescription

// Workstream B (M1): smart import (#2). Dropped decks, recordings and captures are filed to their
// course and lecture/session on their own, with provenance (`filing` rows), Undo and Change.
let package = Package(
    name: "Filing",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Matching (deck footer/title, file numbering, weekly slots, recording start) and the filing
        // service (import via Capture/Processing, Undo, Change).
        .library(name: "Filing", targets: ["Filing"]),
        // SwiftUI: drop destination HUD, filed toast (Undo / Change…), change sheet, sidebar drop targets.
        .library(name: "FilingUI", targets: ["FilingUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        .package(path: "../Capture"),
        .package(path: "../Processing")
    ],
    targets: [
        .target(
            name: "Filing",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "Processing", package: "Processing")
            ]
        ),
        .target(
            name: "FilingUI",
            dependencies: [
                "Filing",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
