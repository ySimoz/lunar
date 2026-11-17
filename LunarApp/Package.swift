// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LunarApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LunarApp", targets: ["LunarApp"])
    ],
    targets: [
        .executableTarget(
            name: "LunarApp",
            path: "Sources/LunarApp",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LunarAppTests",
            dependencies: ["LunarApp"],
            path: "Tests/LunarAppTests"
        )
    ]
)
