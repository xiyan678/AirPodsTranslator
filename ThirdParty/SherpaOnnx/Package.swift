// swift-tools-version: 5.9
import PackageDescription

// Pin the release and its published asset digests together. The upstream
// v1.13.14 manifest references 1.13.2 assets with stale checksums.
let package = Package(
    name: "SherpaOnnx",
    platforms: [.iOS(.v13), .macOS(.v13)],
    products: [.library(name: "SherpaOnnx", targets: ["SherpaOnnx"])],
    targets: [
        .binaryTarget(
            name: "sherpa-onnx",
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/1.13.8/sherpa-onnx.xcframework.zip",
            checksum: "e592886927846382ee69d9162688cab529657e653120af0cc21fd03f73e98813"
        ),
        .binaryTarget(
            name: "onnxruntime",
            path: "Artifacts/onnxruntime.xcframework"
        ),
        .target(
            name: "SherpaOnnx",
            dependencies: ["sherpa-onnx", "onnxruntime"],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")]
        )
    ]
)
