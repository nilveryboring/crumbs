// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crumbs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrumbsCore", targets: ["CrumbsCore"]),
        .executable(name: "crumbs", targets: ["crumbs"]),
    ],
    targets: [
        .target(name: "CrumbsCore", resources: [.copy("Rules")]),
        .executableTarget(name: "crumbs", dependencies: ["CrumbsCore"]),
        .testTarget(name: "CrumbsCoreTests", dependencies: ["CrumbsCore"]),
    ]
)
