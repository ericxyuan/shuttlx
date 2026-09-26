// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShuttlXCore",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v14)],
    products: [.library(name: "ShuttlXCore", targets: ["ShuttlXCore"]), .executable(name: "shuttlx-replay", targets: ["ShuttlXReplay"])],
    targets: [
        .target(name: "ShuttlXCore"),
        .executableTarget(name: "ShuttlXReplay", dependencies: ["ShuttlXCore"]),
        .testTarget(name: "ShuttlXCoreTests", dependencies: ["ShuttlXCore"])
    ]
)

