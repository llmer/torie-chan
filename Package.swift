// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TorieChan",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TorieChan", targets: ["TorieChan"]),
        .executable(name: "bg-mcp", targets: ["bg-mcp"]),
        .executable(name: "bg-helper", targets: ["bg-helper"]),
    ],
    targets: [
        .target(name: "GuardShared"),
        .executableTarget(name: "TorieChan", dependencies: ["GuardShared"]),
        .executableTarget(name: "bg-mcp", dependencies: ["GuardShared"]),
        .executableTarget(name: "bg-helper", dependencies: ["GuardShared"]),
        .testTarget(name: "TorieChanTests", dependencies: ["TorieChan", "GuardShared"]),
    ],
    swiftLanguageModes: [.v5]
)
