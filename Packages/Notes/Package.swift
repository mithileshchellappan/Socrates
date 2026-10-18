// swift-tools-version: 6.2
import PackageDescription

// M6 workstream A (docs/plan-m6.md §5.1): Apple Notes-style notes (PRD #15, #16, mockup 04).
let package = Package(
    name: "Notes",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // No SwiftUI: note names and list order, list times, image and sketch blobs, the pure
        // parts of the blocks ⇄ document mapping (unchanged blocks keep their JSON).
        .library(name: "Notes", targets: ["Notes"]),
        // Platform UI: the Notes screen (`NotesView`), the rich editor (`NoteEditor`, TextKit 2
        // on the Mac; a read-only rendering on iOS), attachments, chips, Slide and Quote pickers.
        .library(name: "NotesUI", targets: ["NotesUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        // Slide clips and the Slide picker draw pages with `SlideDeck` / `SlideImageView`.
        .package(path: "../Capture")
    ],
    targets: [
        .target(
            name: "Notes",
            dependencies: [.product(name: "StudyCore", package: "StudyCore")]
        ),
        .target(
            name: "NotesUI",
            dependencies: [
                "Notes",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "CaptureUI", package: "Capture")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
