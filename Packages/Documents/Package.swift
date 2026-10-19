// swift-tools-version: 6.2
import PackageDescription

// md (docs/plan-docs.md): the document bank (PRD "Document bank"). The
// student's own documents (CV, handbooks, regulations, transcripts, certificates, letters): kept in
// the BlobStore, read on the Mac off the main thread (PDF + OCR, Word, RTF, Pages via its preview,
// text, images by OCR), summarised by one background Haiku task, chunked into Search, and pulled by
// the app agent on demand. Workstream A owns `Documents`, B owns `DocumentsUI`; neither edits
// this file (requests go to the integrator through the README).
let package = Package(
    name: "Documents",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // No SwiftUI: `DocumentBank` (add, read, delete with Undo, resume at launch),
        // `DocumentExtractor` (text per page), `DocumentSummarizer` (the Haiku task, run by
        // AppAgent's task queue).
        .library(name: "Documents", targets: ["Documents"]),
        // Platform UI: the Documents screen (`DocumentsView`), its list, reader, drop and Import…,
        // `DocumentActions` (the app's closures over the bank).
        .library(name: "DocumentsUI", targets: ["DocumentsUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        // The summary's Haiku call (`ClaudeClient`, Claude Code on the student's subscription).
        .package(path: "../ClaudeKit")
    ],
    targets: [
        .target(
            name: "Documents",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit")
            ]
        ),
        .target(
            name: "DocumentsUI",
            dependencies: [
                "Documents",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
