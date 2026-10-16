// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Transcription", targets: ["Transcription"]),
        .executable(name: "TranscribeBench", targets: ["TranscribeBench"])
    ],
    dependencies: [
        .package(path: "../StudyCore"),
        // WhisperKit lives in Argmax's open-source SDK (renamed from WhisperKit at 1.0.0). MIT.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "StudyCore", package: "StudyCore"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
        // Real-model evaluation and benchmarking. Never run by `swift test`.
        .executableTarget(
            name: "TranscribeBench",
            dependencies: [
                "Transcription",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
