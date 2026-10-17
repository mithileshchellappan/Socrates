// swift-tools-version: 6.2
import PackageDescription

// Workstream D (M1): keyword search (#20, FTS5) over transcripts, slides and notes, with results
// that jump to slide + time (mockup 07 without tutor/web).
let package = Package(
    name: "Search",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Indexer (chunks + lemmas into `search_chunk`, kept current) and the query engine.
        .library(name: "Search", targets: ["Search"]),
        // SwiftUI: the search results screen.
        .library(name: "SearchUI", targets: ["SearchUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        .package(path: "../Capture"),
        // Already in the graph through SQLiteData; used directly for `DatabaseRegionObservation`
        // and raw FTS5 SQL (SQLiteData re-exports only a few GRDB types).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0")
    ],
    targets: [
        .target(
            name: "Search",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "SearchUI",
            dependencies: [
                "Search",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "CaptureUI", package: "Capture")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
