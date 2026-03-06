// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "native-gpu-profiler",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ngp", targets: ["NativeGPUProfiler"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "NativeGPUProfiler",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "NativeGPUProfilerTests",
            dependencies: ["NativeGPUProfiler"]
        )
    ]
)
