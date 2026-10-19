// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "clodvm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "clodvm", path: "Sources/clodvm")
    ]
)
