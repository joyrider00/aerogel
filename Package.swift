// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SlackGlass",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SlackGlass",
            path: "Sources/SlackGlass"
        )
    ]
)
