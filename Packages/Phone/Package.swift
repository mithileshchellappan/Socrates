// swift-tools-version: 6.2
import PackageDescription

// M7 workstream B (docs/plan-m7.md §5.2): the iPhone's shell (mockups 09 and 16, DESIGN 6.7, 8.5):
// the floating tab bar Today, Courses, Calendar, Mail, the separate round red Record button, and
// the agent sheet (agent panel mockup §7) from each tab's header. The app passes the screens in.
let package = Package(
    name: "Phone",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "PhoneUI", targets: ["PhoneUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        // The agent sheet (`AgentSheet`) and its actions.
        .package(path: "../ChatUI"),
        // The Record slot shows the recorder's phase (`RecorderSnapshot.Phase`; the contract only).
        .package(path: "../Recorder")
    ],
    targets: [
        .target(
            name: "PhoneUI",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "ChatUI", package: "ChatUI"),
                .product(name: "RecorderContract", package: "Recorder")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
