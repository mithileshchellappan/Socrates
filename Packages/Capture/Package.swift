// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Core: lecture packages, segmented recording, slide stamps, deck rendering, captions,
        // import into the database. No SwiftUI, no AppKit/UIKit API; PDFKit (which re-exports
        // them) is imported internally for slide text only (docs/decisions.md).
        .library(name: "Capture", targets: ["Capture"]),
        // SwiftUI live-lecture screen and menu commands.
        .library(name: "CaptureUI", targets: ["CaptureUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore")
    ],
    targets: [
        .target(
            name: "Capture",
            dependencies: [.product(name: "StudyCore", package: "StudyCore")]
        ),
        .target(
            name: "CaptureUI",
            dependencies: ["Capture"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
