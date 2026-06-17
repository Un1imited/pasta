// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pasta",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Pasta",
            path: "Sources/Pasta"
        )
    ]
)
