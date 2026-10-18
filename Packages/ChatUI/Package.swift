// swift-tools-version: 6.2
import PackageDescription

// ma (docs/plan-agent.md §5.2): the ONE agent panel of the main window, compact and movable or
// the full-height right sidebar: the student's messages, the agent's answers streaming into place,
// change rows with Undo, the task line, the composer with files. Reads `agent_conversation` /
// `agent_turn` / `agent_change` / `agent_task` rows itself (ClaudeKit decodes the stored turn
// JSON); every effect goes through `AgentPanelActions`, which the app wires to AppAgent. Depends
// on no feature package and cannot send mail.
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
