// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YubiWatcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "YubiWatcher", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
