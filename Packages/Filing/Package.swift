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
        .package(path: "../Processing"),
        // mt: books and papers dropped on a course become its materials (`MaterialClassifier`,
        // `MaterialLibrary`): FilingUI only.
        .package(path: "../Documents"),
        // Already in the graph through SQLiteData (same pin as AppAgent); used directly for the
        // schema-driven snapshot of what a delete removes (rows, `PRAGMA foreign_key_list`).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0")
    ],
    targets: [
        .target(
            name: "Filing",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "Processing", package: "Processing"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "FilingUI",
            dependencies: [
                "Filing",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Processing", package: "Processing"),
                .product(name: "Materials", package: "Documents")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
