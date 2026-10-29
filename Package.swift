// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacMonitor", targets: ["MacMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "MacMonitor",
            path: "Sources/MacMonitor",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "MacMonitorTests",
            dependencies: ["MacMonitor"],
            path: "Tests/MacMonitorTests"
        )
    ]
)
