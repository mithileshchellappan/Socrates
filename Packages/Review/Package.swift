// swift-tools-version: 6.2
import PackageDescription

// Workstream C (M1): the lecture review screen (#14, mockup 03) with one playback clock,
// per-slide notes (#15) and manual "slide starts here" (#9).
let package = Package(
    name: "Review",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // No SwiftUI: the recording player (one clock over segment files), the slide ↔ time
        // timeline, follow-playback state, note and anchor editing.
        .library(name: "Review", targets: ["Review"]),
        // SwiftUI: rail, slide, transcript, floating player, inspector with notes.
        .library(name: "ReviewUI", targets: ["ReviewUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        .package(path: "../Capture")
    ],
    targets: [
        .target(
            name: "Review",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture")
            ]
        ),
        .target(
            name: "ReviewUI",
            dependencies: [
                "Review",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "CaptureUI", package: "Capture")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
