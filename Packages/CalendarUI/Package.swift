// swift-tools-version: 6.2
import PackageDescription

// Workstream C (M3, docs/plan-m3.md §5): the Calendar & deadlines screen (mockup 06) — week grid,
// all-day row, now line, sessions, deadlines, proposals, the "Deadlines" inspector and the "New
// deadline" composer — its menu commands and the sidebar's calendar checkboxes. Reads rows from
// StudyCore; every effect goes through StudyUI's `DeadlineActions`; other calendars come through
// CalendarSync, read-only.
let package = Package(
    name: "CalendarUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "CalendarUI", targets: ["CalendarUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        .package(path: "../Courses")
    ],
    targets: [
        .target(
            name: "CalendarUI",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Courses", package: "Courses"),
                .product(name: "CalendarSync", package: "Courses")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
