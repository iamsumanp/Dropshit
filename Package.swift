// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfDemo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ShelfDemo",
            path: "Sources/ShelfDemo",
            // The .icns is consumed only by the packaged .app bundle (copied
            // by scripts/build-dmg.sh). Excluding it here keeps SwiftPM
            // quiet and avoids embedding it in the SPM module's bundle.
            exclude: ["Resources/AppIcon.icns"]
        ),
        .testTarget(
            name: "ShelfDemoTests",
            dependencies: ["ShelfDemo"],
            path: "Tests/ShelfDemoTests"
        ),
    ]
)
