// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RailRouter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "RailRouter",
            path: "RailRouter",
            exclude: ["Info.plist", "Assets.xcassets", "Resources"]
        )
    ]
)
