// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProductivityApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ProductivityApp", targets: ["ProductivityApp"]),
        .library(name: "ProductivityCore", targets: ["ProductivityCore"]),
        .executable(name: "LogicTests", targets: ["LogicTests"])
    ],
    targets: [
        .target(
            name: "ProductivityCore",
            path: "Sources/ProductivityCore"
        ),
        .executableTarget(
            name: "ProductivityApp",
            dependencies: ["ProductivityCore"],
            path: "Sources/ProductivityApp"
        ),
        .executableTarget(
            name: "LogicTests",
            dependencies: ["ProductivityCore"],
            path: "Tests/LogicTests"
        )
    ]
)
