// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreBabelLens",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0"),
        .iOS("26.0")
    ],
    products: [
        .executable(name: "PreBabelLens", targets: ["PreBabelLens"])
    ],
    targets: [
        .executableTarget(
            name: "PreBabelLens",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PreBabelLensTests",
            dependencies: ["PreBabelLens"],
            path: "Tests"
        )
    ]
)
