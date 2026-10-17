// swift-tools-version: 6.2
import PackageDescription

// End-to-end check of lecture processing through the app's own code path (LectureImporter +
// LectureProcessor + WhisperKitEngine). Needs the Whisper model; run in release:
//   swift run -c release --package-path tools/ProcessLecture process-lecture --help
let package = Package(
    name: "ProcessLecture",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/StudyCore"),
        .package(path: "../../Packages/Capture"),
        .package(path: "../../Packages/Transcription"),
        .package(path: "../../Packages/Alignment"),
        .package(path: "../../Packages/Processing")
    ],
    targets: [
        .executableTarget(
            name: "process-lecture",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "Capture", package: "Capture"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "Alignment", package: "Alignment"),
                .product(name: "AlignmentEvaluation", package: "Alignment"),
                .product(name: "Processing", package: "Processing")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
