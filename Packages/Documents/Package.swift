// swift-tools-version: 6.2
import PackageDescription

// md: the document bank (PRD "Document bank", 2026-10-19). The
// student's own documents (CV, handbooks, regulations, transcripts, certificates, letters): kept in
// the BlobStore, read on the Mac off the main thread (PDF + OCR, Word, RTF, Pages via its preview,
// text, images by OCR), summarised by one background Haiku task, chunked into Search, and pulled by
// the app agent on demand. Workstream A owns `Documents`, B owns `DocumentsUI`; neither edits
// this file (requests go to the integrator through the README).
//
// mt (docs/plan-materials.md "Build plan"): course materials share the bank. `Materials` (logic,
// workstream A) reads books, papers, references and links into it with role `material`;
// `MaterialsUI` (workstream B) is the course's Materials screen and the reader. MaterialsUI
// does not depend on Materials: it talks to the library through StudyCore's
// `MaterialLibraryActions`, which the app injects.
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
        .library(name: "DocumentsUI", targets: ["DocumentsUI"]),
        // mt: `MaterialLibrary`, `MaterialClassifier`, `SectionReader`, `LinkFetcher`,
        // `MaterialCard`, `ChapterSummarizer`. No SwiftUI.
        .library(name: "Materials", targets: ["Materials"]),
        // mt: the Materials screen (shelf, reader), `\.materialLibrary`.
        .library(name: "MaterialsUI", targets: ["MaterialsUI"])
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
        .target(
            name: "Materials",
            dependencies: [
                "Documents",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit")
            ]
        ),
        .target(
            name: "MaterialsUI",
            dependencies: [
                "DocumentsUI",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
