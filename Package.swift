// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "DotWakeKeywordOnly", platforms: [.macOS(.v13)], products: [.executable(name: "DotWake", targets: ["DotWake"])], targets: [
.binaryTarget(name: "SherpaOnnxC", path: "Vendor/sherpa-onnx.xcframework"),
.binaryTarget(name: "onnxruntime", path: "Vendor/onnxruntime.xcframework"),
.target(name: "WakeInference", dependencies: ["SherpaOnnxC", "onnxruntime"], linkerSettings: [.linkedLibrary("c++"), .linkedFramework("CoreML")]),
.target(name: "WakeCore"),
.executableTarget(name: "DotWake", dependencies: ["WakeCore", "WakeInference"]),
.testTarget(name: "WakeCoreTests", dependencies: ["WakeCore"])
])
