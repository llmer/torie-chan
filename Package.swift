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
    dependencies: [
        // Auto-updates. Pinned exactly; the release workflow downloads the matching tools.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "GuardShared"),
        .executableTarget(name: "TorieChan", dependencies: ["GuardShared", .product(name: "Sparkle", package: "Sparkle")],
                          // Sparkle.framework is embedded in Torie-chan.app/Contents/Frameworks.
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "bg-mcp", dependencies: ["GuardShared"]),
        .executableTarget(name: "bg-helper", dependencies: ["GuardShared"]),
        .testTarget(name: "TorieChanTests", dependencies: ["TorieChan", "GuardShared", "bg-mcp"]),
    ],
    swiftLanguageModes: [.v5]
)
