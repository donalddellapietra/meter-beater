// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageTracker",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AIUsageTracker", targets: ["AIUsageTracker"]),
        .executable(name: "AIUsageTrackerIndexBenchmark", targets: ["AIUsageTrackerIndexBenchmark"]),
        .library(name: "UsageCore", targets: ["UsageCore"])
    ],
    targets: [
        .executableTarget(name: "AIUsageTracker", dependencies: ["UsageCore"]),
        .executableTarget(name: "AIUsageTrackerIndexBenchmark", dependencies: ["UsageCore"]),
        .target(name: "UsageCore", dependencies: ["FastScanner"]),
        .target(name: "FastScanner", publicHeadersPath: "include"),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"])
    ]
)
