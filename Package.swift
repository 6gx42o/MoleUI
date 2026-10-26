// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoleUI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MoleUI",
            path: "Sources/MoleUI",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
