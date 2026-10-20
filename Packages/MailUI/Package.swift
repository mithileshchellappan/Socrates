// swift-tools-version: 6.2
import PackageDescription

// Workstream C (M2): the Mail screen (mockup 05: message list, reader with what was found,
// inline reply with Send), the sidebar's mail rows, Message commands and the mail account
// settings. Reads rows from StudyCore; every action with an effect goes through `MailActions`,
// which the app wires to Mail (sync, send) and MailIntelligence (routing, drafts, Undo).
let package = Package(
    name: "MailUI",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MailUI", targets: ["MailUI"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        // Translate: local-translate's OPUS-MT models on the device (docs/plan-translation.md).
        .package(path: "../LocalTranslation")
    ],
    targets: [
        .target(
            name: "MailUI",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "LocalTranslation", package: "LocalTranslation")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
