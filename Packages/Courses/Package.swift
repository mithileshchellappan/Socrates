// swift-tools-version: 6.2
import PackageDescription

// Workstream A (M1): course setup (#1), weekly slots → lecture sessions, the app-owned
// "Study Portal" calendar (#36), the course setup screen (mockup 08) and a light Today (mockup 01).
let package = Package(
    name: "Courses",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Pure logic: course drafts/validation, session planning from weekly slots and the semester.
        .library(name: "Courses", targets: ["Courses"]),
        // EventKit mirror of lecture sessions into the app-owned "Study Portal" calendar.
        .library(name: "CalendarSync", targets: ["CalendarSync"]),
        // SwiftUI: course setup (08), new course, semester settings, light Today (01; mc: the plan's
        // hero, mockups 11–12).
        .library(name: "CoursesUI", targets: ["CoursesUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        // mc: Today's hero is the plan's first block (`PlanHero`).
        .package(path: "../Coach")
    ],
    targets: [
        .target(
            name: "Courses",
            dependencies: [.product(name: "StudyCore", package: "StudyCore")]
        ),
        .target(
            name: "CalendarSync",
            dependencies: ["Courses", .product(name: "StudyCore", package: "StudyCore")]
        ),
        .target(
            name: "CoursesUI",
            dependencies: [
                "Courses", "CalendarSync",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "CoachUI", package: "Coach")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
