// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "UsageMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "UsageMonitor", targets: ["UsageMonitor"])
    ],
    targets: [
        .executableTarget(name: "UsageMonitor", path: "Sources/UsageBar")
    ]
)
