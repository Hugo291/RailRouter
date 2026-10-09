// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TchouTchou",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "TchouTchou",
            path: "TchouTchou",
            exclude: ["Info.plist", "Assets.xcassets", "Resources"]
        )
    ]
)
