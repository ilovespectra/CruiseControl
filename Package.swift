// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CruiseControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CruiseControl", targets: ["CruiseControl"]),
    ],
    targets: [
        .target(name: "CruiseCore", path: "Sources/CruiseCore"),
        .executableTarget(
            name: "CruiseControl",
            dependencies: ["CruiseCore"],
            path: "Sources/CruiseControl"
        ),
        .testTarget(
            name: "CruiseCoreTests",
            dependencies: ["CruiseCore"],
            path: "Tests/CruiseCoreTests"
        ),
    ]
)
