// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "LocalReelCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LocalReelCore", targets: ["LocalReelCore"])],
    dependencies: [.package(path: "Vendor/YouTubeKit")],
    targets: [
        .target(name: "LocalReelCore", dependencies: [.product(name: "YouTubeKit", package: "YouTubeKit")], path: "Shared"),
        .testTarget(name: "LocalReelCoreTests", dependencies: ["LocalReelCore"], path: "CoreTests")
    ]
)
