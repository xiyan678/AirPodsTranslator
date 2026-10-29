// swift-tools-version: 5.9
import PackageDescription

// Both binaries come from one verified official iOS release. Do not mix runtime ABIs.
let package = Package(
    name: "SherpaOnnx",
    platforms: [.iOS(.v13), .macOS(.v13)],
    products: [.library(name: "SherpaOnnx", targets: ["SherpaOnnx"])],
    targets: [
        .binaryTarget(name: "sherpa-onnx", path: "Artifacts/paired-ios/sherpa-onnx.xcframework"),
        .binaryTarget(name: "onnxruntime", path: "Artifacts/paired-ios/onnxruntime.xcframework"),
        .target(name: "SherpaRuntimeCheck", dependencies: ["onnxruntime"]),
        .target(
            name: "SherpaOnnx",
            dependencies: ["sherpa-onnx", "onnxruntime", "SherpaRuntimeCheck"],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")]
        )
    ]
)
