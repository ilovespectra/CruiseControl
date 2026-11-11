// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CruiseControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CruiseControl", targets: ["CruiseControl"]),
        .executable(name: "CruiseControlPublisher", targets: ["CruiseControlPublisher"]),
    ],
    targets: [
        .target(name: "CruiseCore", path: "Sources/CruiseCore"),
        .target(name: "CruiseAudioAtomics",
                path: "Sources/CruiseAudioAtomics",
                publicHeadersPath: "include"),
        .executableTarget(name: "CruiseControlPublisher", path: "Sources/CruiseControlPublisher"),
        .executableTarget(
            name: "CruiseControl",
            dependencies: ["CruiseCore", "CruiseAudioAtomics"],
            path: "Sources/CruiseControl"
        ),
        .testTarget(
            name: "CruiseCoreTests",
            dependencies: ["CruiseCore"],
            path: "Tests/CruiseCoreTests"
        ),
    ],
    cLanguageStandard: .c11
)
