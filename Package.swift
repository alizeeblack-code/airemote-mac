// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIRemoteMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AIRemoteMac",
            path: "Sources/AIRemoteMac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
