// swift-tools-version: 6.2
import PackageDescription

// Mail's Translate on the device with local-translate's OPUS-MT models (docs/plan-translation.md):
// `Xenova/opus-mt-<src>-<tgt>` q8 ONNX graphs (encoder + merged decoder), run on ONNX Runtime's
// CPU execution provider through a small C shim (the Objective-C binding has no bool tensors,
// and the merged decoder's `use_cache_branch` is one). Logic only; no StudyCore, no UI.
let package = Package(
    name: "LocalTranslation",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "LocalTranslation", targets: ["LocalTranslation"])
    ],
    targets: [
        // The ONNX Runtime C/C++ pod archive the official Swift package pins for 1.24.2 (static
        // xcframework: macOS arm64/x86_64, iOS, iOS Simulator; C headers). MIT.
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip",
            checksum: "f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
        ),
        // The dozen C calls the engine needs, behind opaque handles and `char *` errors. The
        // static runtime is C++ and carries the Core ML execution provider (unused, but linked).
        .target(
            name: "COnnxRuntime",
            dependencies: ["onnxruntime"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "LocalTranslation",
            dependencies: ["COnnxRuntime"]
        )
    ],
    swiftLanguageModes: [.v6]
)
