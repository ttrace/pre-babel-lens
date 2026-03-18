// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PreBabelLens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PreBabelLens", targets: ["PreBabelLens"])
    ],
    targets: [
        .executableTarget(
            name: "PreBabelLens",
            path: "Sources"
        ),
        .testTarget(
            name: "PreBabelLensTests",
            dependencies: ["PreBabelLens"],
            path: "Tests"
        )
    ]
)
