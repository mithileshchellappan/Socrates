// swift-tools-version: 6.2
import PackageDescription

// Workstream A (M2): university mail transport. IMAP sync (SwiftMail) into `mailbox` /
// `mail_message` rows with checkpoints, IDLE, flag and move write-back; MIME parsing and safe
// HTML-to-text; SMTP sending of drafts (the Send button only) with the copy appended to Sent.
// The agent never reaches this package (MailIntelligence does not depend on it).
let package = Package(
    name: "Mail",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Mail", targets: ["Mail"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        // IMAP + SMTP (BSD-2). 1.15.0 (2026-10-07): IDLE sessions with renewal and reconnect,
        // SPECIAL-USE, UIDPLUS, MOVE, APPEND, ENABLE + QRESYNC select, STARTTLS / implicit TLS,
        // EMLParser. 1.16.0 pins swift-nio-imap by revision, which SwiftPM refuses in a versioned
        // dependency, so this stays on 1.15.x (docs/decisions.md).
        .package(url: "https://github.com/Cocoanetics/SwiftMail", .upToNextMinor(from: "1.15.0")),
        // Already a SwiftMail dependency (resolved 0.4.0); named here because SwiftMail's API
        // exposes its `Capability` and `ModificationSequenceValue` types.
        .package(url: "https://github.com/apple/swift-nio-imap", from: "0.4.0")
    ],
    targets: [
        .target(
            name: "Mail",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "SwiftMail", package: "SwiftMail"),
                .product(name: "NIOIMAP", package: "swift-nio-imap")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
