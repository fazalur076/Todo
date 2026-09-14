// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Todo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Todo", targets: ["Todo"]),
        .library(name: "ProductivityCore", targets: ["ProductivityCore"]),
        .executable(name: "LogicTests", targets: ["LogicTests"])
    ],
    targets: [
        .target(
            name: "ProductivityCore",
            path: "Sources/ProductivityCore",
            resources: [
                .copy("Resources/note_extractor.py")
            ]
        ),
        .executableTarget(
            name: "Todo",
            dependencies: ["ProductivityCore"],
            path: "Sources/ProductivityApp",
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .executableTarget(
            name: "LogicTests",
            dependencies: ["ProductivityCore"],
            path: "Tests/LogicTests"
        )
    ]
)
