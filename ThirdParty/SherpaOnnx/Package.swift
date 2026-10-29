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
            url: "https://github.com/willwade/sherpa-onnx-spm/releases/download/1.13.8/onnxruntime.xcframework.zip",
            checksum: "5a18cf7abd25800d77e7365f7f05dc8322d2deed8bde8daa57ba2c282fec4ea5"
        ),
        .target(
            name: "SherpaOnnx",
            dependencies: ["sherpa-onnx", "onnxruntime"],
            linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")]
        )
    ]
)
