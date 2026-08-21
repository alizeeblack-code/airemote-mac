// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JoyCoding",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JoyCoding",
            path: "Sources/JoyCoding",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
