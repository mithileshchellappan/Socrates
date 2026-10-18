// swift-tools-version: 6.2
import PackageDescription

// Milestone mc (docs/plan-coach.md): the study coach.
//   Coach    workstream A, logic only (no SwiftUI): the plan engine (budget, phases, day plans as
//            `study_block` rows), the FSRS scheduler, rounds and practice exam assembly, Haiku
//            question drafting (run by the AppAgent task queue), Opus grading of written answers,
//            old exams, the university profile's items. `CoachEngine` implements `StudyCoaching`.
//   CoachUI  workstream B, SwiftUI: the plan hero (Today and Study), Study, a course's Progress,
//            the practice round, the practice exam (sheet, exam, results).
// Each target's dependency list is edited only by its owner. CoachUI never imports Coach: they
// meet in StudyCore's rows and measures and StudyUI's `\.studyCoach`.
let package = Package(
    name: "Coach",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Coach", targets: ["Coach"]),
        .library(name: "CoachUI", targets: ["CoachUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        .package(path: "../ClaudeKit"),
        .package(path: "../Agent"),
        .package(path: "../StudyPass"),
        .package(path: "../Capture"),
        // Already in the graph through SQLiteData; `DatabaseRegionObservation` (the engine follows
        // the rows it plans from).
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0")
    ],
    targets: [
        .target(
            name: "Coach",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "ClaudeKit", package: "ClaudeKit"),
                .product(name: "Deadlines", package: "Agent"),
                .product(name: "StudyPass", package: "StudyPass"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "CoachUI",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "CaptureUI", package: "Capture")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
