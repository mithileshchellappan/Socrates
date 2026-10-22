// swift-tools-version: 6.2
import PackageDescription

// M7 workstream A (docs/plan-m7.md §5.1): the iPhone recorder (PRD #3, #42, mockup 09), its Live
// Activity and the outbox of phone captures shared to the Mac as capture bundles. The recorder is
// driven through one command contract (`RecorderContract`, README "Recorder contract").
let package = Package(
    name: "Recorder",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // The recorder's command and snapshot contract (Foundation only, no UI, no transport):
        // what every surface sends and renders, and what the Mac remote will speak.
        .library(name: "RecorderContract", targets: ["RecorderContract"]),
        // The Live Activity's contract, shared by the app and the widget extension: its state and
        // attributes (ActivityKit, iOS) and the hook its buttons call in the app's process. No
        // StudyCore, so the extension stays small.
        // RecorderContract rides along, so the widget extension reaches it without its own product.
        .library(name: "RecorderActivity", targets: ["RecorderActivity", "RecorderContract"]),
        // The phone's recording model over Capture's `LiveLectureSession`: courses that may record,
        // the session on now, stamps, the Live Activity, the outbox (`AppPaths.phoneCaptures`).
        .library(name: "Recorder", targets: ["Recorder"]),
        // SwiftUI: the recorder screen (mockup 09 left), the outbox list, Share to the Mac.
        .library(name: "RecorderUI", targets: ["RecorderUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        .package(path: "../Capture"),
        // `CourseSchedule.session(forRecordingAt:)`: the class a recording started now belongs to.
        .package(path: "../Courses")
    ],
    targets: [
        .target(name: "RecorderContract"),
        .target(name: "RecorderActivity", dependencies: ["RecorderContract"]),
        .target(
            name: "Recorder",
            dependencies: [
                "RecorderContract",
                "RecorderActivity",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "Courses", package: "Courses")
            ]
        ),
        .target(
            name: "RecorderUI",
            dependencies: [
                "Recorder",
                "RecorderContract",
                "RecorderActivity",
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "CaptureUI", package: "Capture")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
