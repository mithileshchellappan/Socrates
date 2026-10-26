// swift-tools-version: 6.2
import PackageDescription

// The recording link (docs/decisions.md, 2026-10-26): recordings made on the iPhone reach the Mac
// by themselves over a direct, mutually pinned TLS link (Bonjour on Wi-Fi, Ethernet, the USB
// cable and, during classes that record, peer-to-peer Wi-Fi), and the Mac shows and controls the
// iPhone's recording (Pause, Resume, Next Slide, Stop). Trust comes from the student's own
// `link_device` rows in the synced library, so the link exists only in the iCloud build.
//
// Dependencies point one way: Link → Recorder (its contract only), Capture, StudyCore. The
// Recorder package never depends on Link; the phone's outbox shows the link's state through a
// view slot the app fills.
let package = Package(
    name: "Link",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Values and pure rules: the protocol's messages and framing, the policy constants, the
        // inbox's path rules, the peer-to-peer window, the self-signed certificate. No I/O.
        .library(name: "LinkCore", targets: ["LinkCore"]),
        // Everything with I/O, behind two main-actor models: `PhoneLink` (the Mac: the phone's
        // recording and the arrivals) and `MacLink` (the iPhone: what the Mac holds of each capture).
        .library(name: "Link", targets: ["Link"]),
        // SwiftUI only: the Mac's menu bar extra, toolbar capsule and Lecture menu items, and the
        // phone outbox row's delivery label.
        .library(name: "LinkUI", targets: ["LinkUI"]),
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../StudyUI"),
        // `LecturePackage` and its reader (the outbox and the inbox's checks); CaptureUI's `ClockText`.
        .package(path: "../Capture"),
        // `RecorderContract` only: the snapshot, the commands and `RecorderEndpoint`.
        .package(path: "../Recorder"),
        // Already in the graph through SQLiteData; `DatabaseRegionObservation` follows `link_device`.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.6.0"),
    ],
    targets: [
        .target(
            name: "LinkCore",
            dependencies: [
                .product(name: "RecorderContract", package: "Recorder"),
            ]
        ),
        .target(
            name: "Link",
            dependencies: [
                "LinkCore",
                .product(name: "RecorderContract", package: "Recorder"),
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "LinkUI",
            dependencies: [
                "Link",
                "LinkCore",
                .product(name: "RecorderContract", package: "Recorder"),
                .product(name: "StudyUI", package: "StudyUI"),
                .product(name: "CaptureUI", package: "Capture"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
