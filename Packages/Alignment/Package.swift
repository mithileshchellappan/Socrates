// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Alignment",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "Alignment", targets: ["Alignment"])
    ],
    targets: [
        // The aligner itself: pure Swift, no dependencies, no I/O besides SRT parsing of strings.
        .target(name: "Alignment"),
        // Fixture loading, ground truth and scoring. Shared by the tests and the eval CLI; not a product.
        .target(name: "AlignmentEvaluation", dependencies: ["Alignment"]),
        // `swift run -c release --package-path Packages/Alignment alignment-eval` prints docs/eval tables.
        .executableTarget(name: "alignment-eval", dependencies: ["Alignment", "AlignmentEvaluation"]),
    ],
    swiftLanguageModes: [.v6]
)
