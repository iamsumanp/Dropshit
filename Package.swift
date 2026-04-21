// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfDemo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ShelfDemo", path: "Sources/ShelfDemo"),
    ]
)
