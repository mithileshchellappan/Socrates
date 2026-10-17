// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Processing",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        // Lecture import (captured packages, audio + PDF) and the persisted job pipeline:
        // transcribe → align, writing transcript segments and slide spans to the database.
        .library(name: "Processing", targets: ["Processing"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        .package(path: "../Capture"),
        .package(path: "../Transcription"),
        .package(path: "../Alignment")
    ],
    targets: [
        .target(
            name: "Processing",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "Alignment", package: "Alignment")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
