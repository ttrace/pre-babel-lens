// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChampollionDeck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ChampollionDeckApp", targets: ["ChampollionDeckApp"])
    ],
    targets: [
        .executableTarget(
            name: "ChampollionDeckApp",
            path: "Sources"
        ),
        .testTarget(
            name: "ChampollionDeckTests",
            dependencies: ["ChampollionDeckApp"],
            path: "Tests"
        )
    ]
)
