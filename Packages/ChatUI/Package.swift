// swift-tools-version: 6.2
import PackageDescription

// M3.5 (workstream B): the chat with the agent in the right inspector of Today and Mail (mockup
// 07's tutor look): the student's messages, the agent's answers streaming into place, the
// composer. Reads `agent_conversation` / `agent_turn` rows itself (ClaudeKit decodes the stored
// turn JSON); every effect goes through `ChatActions`, which the app wires to the agent runtime
// and MailIntelligence's `MailChat`. Depends on no feature package and cannot send mail.
let package = Package(
    name: "ChatUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "ChatUI", targets: ["ChatUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        .package(path: "../ClaudeKit")
    ],
    targets: [
        .target(
            name: "ChatUI",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "ClaudeKit", package: "ClaudeKit")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
